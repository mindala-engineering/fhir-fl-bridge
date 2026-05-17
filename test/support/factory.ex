defmodule FhirFlBridge.Factory do
  @moduledoc """
  Fábrica de dados de teste usando ExMachina.

  Centraliza a criação de structs e mapas de teste para evitar
  duplicação e manter os testes legíveis.

  Uso:
      import FhirFlBridge.Factory

      # Retorna struct não persistida
      concept_result = build(:lexicon_search_result)

      # Persiste no banco (requer Ecto.Sandbox)
      mapping = insert(:concept_mapping)
      round = insert(:fl_round, status: "completed")
  """

  use ExMachina.Ecto, repo: FhirFlBridge.Repo

  alias FhirFlBridge.Repo.Schemas.{FLRound, FLParticipant, ConceptMapping}

  # -------------------------------------------------------------------
  # Resultados simulados do Lexicon Vivo (P1)
  # -------------------------------------------------------------------

  def lexicon_search_result_factory do
    %{
      concept_id: Ecto.UUID.generate(),
      label: sequence(:label, &"Conceito MTCI #{&1}"),
      lucene_score: 0.87,
      confidence_score: 0.91,
      tradition: "TCM",
      fhir_code: sequence(:fhir_code, &"TCM-#{String.pad_leading("#{&1}", 3, "0")}")
    }
  end

  def lexicon_search_result_pending_factory do
    build(:lexicon_search_result, confidence_score: 0.70, lucene_score: 0.65)
  end

  def lexicon_search_result_rejected_factory do
    build(:lexicon_search_result, confidence_score: 0.30, lucene_score: 0.40)
  end

  def lexicon_concept_detail_factory do
    %{
      id: Ecto.UUID.generate(),
      label: "Acupuntura",
      confidence_score: 0.91,
      tradition: "TCM",
      relations: [
        %{"type" => "skos:broader", "target" => "TCM-NEEDLES", "label" => "Terapias com Agulhas"},
        %{"type" => "skos:related", "target" => "TCM-QI", "label" => "Qi"}
      ],
      fhir_code: "TCM-ACUP-001",
      skos_broader: ["TCM-NEEDLES"],
      skos_narrower: ["TCM-ACUP-SCALP", "TCM-ACUP-EAR"]
    }
  end

  # -------------------------------------------------------------------
  # Recursos FHIR de entrada (enviados pelos municípios)
  # -------------------------------------------------------------------

  def fhir_observation_factory do
    %{
      "resourceType" => "Observation",
      "code" => %{
        "coding" => [
          %{
            "system" => "urn:oid:2.16.840.1.113883.13.236",
            "code" => sequence(:code, &"local-code-#{&1}"),
            "display" => "Acupuntura sistêmica"
          }
        ],
        "text" => "Acupuntura para dor lombar crônica"
      },
      "status" => "final"
    }
  end

  def fhir_observation_no_text_factory do
    %{
      "resourceType" => "Observation",
      "code" => %{
        "coding" => [
          %{
            "system" => "urn:oid:2.16.840.1.113883.13.236",
            "code" => "plantas-001",
            "display" => "Plantas medicinais"
          }
        ]
        # Sem campo "text" — testa fallback para "display"
      }
    }
  end

  def fhir_observation_invalid_factory do
    %{
      "resourceType" => "Observation"
      # Sem campo "code" — deve retornar {:error, :no_coding}
    }
  end

  # -------------------------------------------------------------------
  # Schemas Ecto (persistíveis no banco)
  # -------------------------------------------------------------------

  def concept_mapping_factory do
    %ConceptMapping{
      original_code: sequence(:original_code, &"local-#{&1}"),
      original_system: "urn:oid:2.16.840.1.113883.13.236",
      canonical_concept_id: Ecto.UUID.generate(),
      confidence_score: 0.91,
      lucene_score: 0.87,
      status: "auto_accepted",
      municipality_code: "4205407",
      fhir_resource_type: "Observation",
      mapped_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  def concept_mapping_pending_factory do
    build(:concept_mapping, confidence_score: 0.70, status: "pending_review")
  end

  def concept_mapping_rejected_factory do
    build(:concept_mapping, confidence_score: 0.30, status: "rejected", canonical_concept_id: nil)
  end

  def fl_round_factory do
    %FLRound{
      id: Ecto.UUID.generate(),
      status: "pending",
      model_version: 1,
      aggregation_strategy: "weighted_fedavg",
      total_participants: 2,
      completed_participants: 0,
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  def fl_round_completed_factory do
    build(:fl_round,
      status: "completed",
      completed_participants: 2,
      global_weights: %{"layer_1" => [0.1, 0.2, 0.3], "layer_2" => [0.4, 0.5]},
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
  end

  def fl_participant_factory do
    %FLParticipant{
      municipality_code: sequence(:municipality, fn n ->
        municipalities = ["4205407", "4202404", "4209102", "4213500"]
        Enum.at(municipalities, rem(n, length(municipalities)))
      end),
      node_url: sequence(:node_url, &"http://node-#{&1}:8080"),
      confidence_weight: 0.85,
      status: "invited"
    }
  end

  def fl_participant_submitted_factory do
    build(:fl_participant,
      status: "submitted",
      local_gradients: %{"layer_1" => [0.1, 0.2, 0.3]},
      samples_count: 100,
      submitted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
  end
end
