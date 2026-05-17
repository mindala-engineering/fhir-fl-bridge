defmodule FhirFlBridge.FHIR.MapperTest do
  @moduledoc """
  Testes do Mapper FHIR ↔ Lexicon Vivo.

  Usa Mox para mockar o cliente P1 — testes completamente isolados,
  sem dependência de rede ou do serviço P1 rodando.

  Padrão: `expect` define o que o mock deve retornar para cada cenário.
  """

  use ExUnit.Case, async: true

  import Mox
  import FhirFlBridge.Factory

  alias FhirFlBridge.FHIR.Mapper

  # Garante que todos os expects foram chamados exatamente como definidos
  setup :verify_on_exit!

  # -------------------------------------------------------------------
  # map_resource/2 — caso auto_accepted (score >= 0.85)
  # -------------------------------------------------------------------

  describe "map_resource/2 — mapeamento auto_accepted" do
    test "retorna auto_accepted quando P1 retorna score >= 0.85" do
      fhir = build(:fhir_observation)
      lexicon_result = build(:lexicon_search_result, confidence_score: 0.91)

      FhirFlBridge.Lexicon.ClientMock
      |> expect(:search, fn _query, _min_confidence ->
        {:ok, [lexicon_result]}
      end)

      assert {:ok, mapping} = Mapper.map_resource(fhir, "4205407")

      assert mapping.status == :auto_accepted
      assert mapping.confidence_score == 0.91
      assert mapping.requires_human_review == false
      assert mapping.fhir_coding != nil
      assert mapping.municipality_code == "4205407"
      assert mapping.fhir_resource_type == "Observation"
    end

    test "fhir_coding tem o sistema canônico da Mindala" do
      fhir = build(:fhir_observation)
      lexicon_result = build(:lexicon_search_result, confidence_score: 0.92, label: "Acupuntura")

      FhirFlBridge.Lexicon.ClientMock
      |> expect(:search, fn _query, _min_confidence ->
        {:ok, [lexicon_result]}
      end)

      {:ok, mapping} = Mapper.map_resource(fhir, "4205407")

      assert mapping.fhir_coding["system"] == "https://mindala.health/fhir/CodeSystem/lexicon-vivo"
      assert mapping.fhir_coding["display"] == "Acupuntura"
    end
  end

  # -------------------------------------------------------------------
  # map_resource/2 — caso pending_review (0.50 <= score < 0.85)
  # -------------------------------------------------------------------

  describe "map_resource/2 — mapeamento pending_review" do
    test "retorna pending_review quando score está entre 0.50 e 0.84" do
      fhir = build(:fhir_observation)
      lexicon_result = build(:lexicon_search_result_pending)

      FhirFlBridge.Lexicon.ClientMock
      |> expect(:search, fn _query, _min_confidence ->
        {:ok, [lexicon_result]}
      end)

      assert {:ok, mapping} = Mapper.map_resource(fhir, "4205407")

      assert mapping.status == :pending_review
      assert mapping.requires_human_review == true
      # fhir_coding não é gerado para pending_review
      assert mapping.fhir_coding == nil
    end
  end

  # -------------------------------------------------------------------
  # map_resource/2 — caso rejected (score < 0.50)
  # -------------------------------------------------------------------

  describe "map_resource/2 — mapeamento rejected" do
    test "retorna rejected quando score < 0.50" do
      fhir = build(:fhir_observation)
      lexicon_result = build(:lexicon_search_result_rejected)

      FhirFlBridge.Lexicon.ClientMock
      |> expect(:search, fn _query, _min_confidence ->
        {:ok, [lexicon_result]}
      end)

      assert {:ok, mapping} = Mapper.map_resource(fhir, "4205407")

      assert mapping.status == :rejected
      assert mapping.requires_human_review == true
    end

    test "retorna rejected quando P1 não encontra nenhum conceito" do
      fhir = build(:fhir_observation)

      FhirFlBridge.Lexicon.ClientMock
      |> expect(:search, fn _query, _min_confidence ->
        {:ok, []}
      end)

      assert {:ok, mapping} = Mapper.map_resource(fhir, "4205407")

      assert mapping.status == :rejected
      assert mapping.canonical_concept_id == nil
      assert mapping.confidence_score == 0.0
    end
  end

  # -------------------------------------------------------------------
  # map_resource/2 — erros de entrada
  # -------------------------------------------------------------------

  describe "map_resource/2 — erros de entrada FHIR" do
    test "retorna erro para recurso FHIR sem campo 'code'" do
      fhir_invalido = build(:fhir_observation_invalid)

      # P1 NÃO deve ser chamado — erro detectado antes da busca
      assert {:error, {:invalid_fhir, _msg}} = Mapper.map_resource(fhir_invalido, "4205407")
    end

    test "usa display como fallback quando não há campo 'text'" do
      fhir = build(:fhir_observation_no_text)

      FhirFlBridge.Lexicon.ClientMock
      |> expect(:search, fn query, _min_confidence ->
        # Verifica que o query veio do campo 'display'
        assert query == "Plantas medicinais"
        {:ok, [build(:lexicon_search_result, confidence_score: 0.88)]}
      end)

      assert {:ok, mapping} = Mapper.map_resource(fhir, "4205407")
      assert mapping.status == :auto_accepted
    end

    test "retorna erro quando P1 retorna erro HTTP" do
      fhir = build(:fhir_observation)

      FhirFlBridge.Lexicon.ClientMock
      |> expect(:search, fn _query, _min_confidence ->
        {:error, {:http_error, :econnrefused}}
      end)

      assert {:error, {:http_error, :econnrefused}} = Mapper.map_resource(fhir, "4205407")
    end
  end

  # -------------------------------------------------------------------
  # extract_primary_coding/1
  # -------------------------------------------------------------------

  describe "extract_primary_coding/1" do
    test "extrai o primeiro coding de code.coding" do
      fhir = %{
        "code" => %{
          "coding" => [
            %{"system" => "urn:local", "code" => "acup-001"},
            %{"system" => "urn:other", "code" => "acup-002"}
          ]
        }
      }

      assert {:ok, coding} = Mapper.extract_primary_coding(fhir)
      assert coding["code"] == "acup-001"
    end

    test "retorna erro para recurso sem coding" do
      assert {:error, :no_coding} = Mapper.extract_primary_coding(%{})
      assert {:error, :no_coding} = Mapper.extract_primary_coding(%{"code" => %{}})
    end
  end

  # -------------------------------------------------------------------
  # pick_best_result/1
  # -------------------------------------------------------------------

  describe "pick_best_result/1" do
    test "seleciona o resultado com maior confidence_score" do
      results = [
        %{concept_id: "a", confidence_score: 0.70},
        %{concept_id: "b", confidence_score: 0.91},
        %{concept_id: "c", confidence_score: 0.80}
      ]

      best = Mapper.pick_best_result(results)
      assert best.concept_id == "b"
      assert best.confidence_score == 0.91
    end

    test "retorna nil para lista vazia" do
      assert Mapper.pick_best_result([]) == nil
    end
  end
end
