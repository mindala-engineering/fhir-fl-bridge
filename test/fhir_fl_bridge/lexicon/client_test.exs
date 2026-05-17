defmodule FhirFlBridge.Lexicon.ClientTest do
  @moduledoc """
  Testes do cliente Tesla para o Lexicon Vivo (P1).

  Usa `Bypass` para simular o servidor P1 localmente — sem necessidade
  de P1 rodando. Bypass intercepta requisições HTTP reais e responde
  com fixtures controladas, testando o comportamento do cliente em
  condições de sucesso, falha e indisponibilidade.
  """

  use ExUnit.Case, async: true

  alias FhirFlBridge.Lexicon.Client

  # -------------------------------------------------------------------
  # search/2
  # -------------------------------------------------------------------

  describe "search/2" do
    test "retorna resultados quando P1 responde com 200" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/v1/search/", fn conn ->
        body =
          Jason.encode!(%{
            results: [
              %{
                concept_id: "uuid-acupuntura",
                label: "Acupuntura",
                luceneScore: 0.87,
                confidenceScore: 0.91,
                tradition: "TCM",
                fhir_code: "TCM-ACUP-001"
              }
            ]
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end)

      # Cria cliente com URL do Bypass
      client = client_with_url("http://localhost:#{bypass.port}")

      assert {:ok, [result]} = Client.search_with_client(client, "acupuntura", 0.5)
      assert result.concept_id == "uuid-acupuntura"
      assert result.confidence_score == 0.91
      assert result.lucene_score == 0.87
      assert result.tradition == "TCM"
    end

    test "retorna lista vazia quando P1 responde com 404" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/v1/search/", fn conn ->
        Plug.Conn.send_resp(conn, 404, ~s({"detail": "not found"}))
      end)

      client = client_with_url("http://localhost:#{bypass.port}")
      assert {:ok, []} = Client.search_with_client(client, "termo_inexistente", 0.9)
    end

    test "retorna erro quando P1 está indisponível" do
      # Bypass fechado = conexão recusada
      bypass = Bypass.open()
      Bypass.down(bypass)

      client = client_with_url("http://localhost:#{bypass.port}")
      assert {:error, {:http_error, _reason}} = Client.search_with_client(client, "acupuntura", 0.5)
    end

    test "retorna erro em status 500" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/v1/search/", fn conn ->
        Plug.Conn.send_resp(conn, 500, ~s({"error": "internal server error"}))
      end)

      client = client_with_url("http://localhost:#{bypass.port}")
      assert {:error, {:unexpected_status, 500, _}} = Client.search_with_client(client, "acupuntura", 0.5)
    end
  end

  # -------------------------------------------------------------------
  # get_concept/2
  # -------------------------------------------------------------------

  describe "get_concept/2" do
    test "retorna conceito completo com relações SKOS" do
      bypass = Bypass.open()
      concept_id = "uuid-acupuntura-123"

      Bypass.expect_once(bypass, "GET", "/v1/concepts/#{concept_id}", fn conn ->
        body =
          Jason.encode!(%{
            id: concept_id,
            label: "Acupuntura",
            confidenceScore: 0.91,
            tradition: "TCM",
            fhir_code: "TCM-ACUP-001",
            relations: [
              %{type: "skos:broader", target: "TCM-NEEDLES"}
            ],
            broader: ["TCM-NEEDLES"],
            narrower: ["TCM-ACUP-SCALP"]
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end)

      client = client_with_url("http://localhost:#{bypass.port}")
      assert {:ok, concept} = Client.get_concept_with_client(client, concept_id, true)

      assert concept.id == concept_id
      assert concept.label == "Acupuntura"
      assert concept.confidence_score == 0.91
      assert length(concept.relations) == 1
    end

    test "retorna :not_found para conceito inexistente" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/v1/concepts/uuid-inexistente", fn conn ->
        Plug.Conn.send_resp(conn, 404, ~s({"detail": "not found"}))
      end)

      client = client_with_url("http://localhost:#{bypass.port}")
      assert {:error, :not_found} = Client.get_concept_with_client(client, "uuid-inexistente", true)
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  # Cria instância do cliente Tesla com URL customizada (para Bypass)
  # Nota: em produção, a URL vem do Application config.
  # Esta função é um helper de teste que permite injetar a URL do Bypass.
  defp client_with_url(url) do
    Tesla.client([
      {Tesla.Middleware.BaseUrl, url},
      Tesla.Middleware.JSON,
      {Tesla.Middleware.Timeout, timeout: 5_000}
    ])
  end
end
