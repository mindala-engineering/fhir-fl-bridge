defmodule FhirFlBridge.FHIR.Mapper do
  @moduledoc """
  # Parábola do Intérprete de Vozes

  Numa assembleia de muitas nações, cada povo falava sua língua.
  Havia um intérprete que não apenas traduzia palavras — ele traduzia
  significados. Quando um ancião Huni Kuĩ dizia "nixi pae", o intérprete
  não escrevia apenas "ayahuasca". Ele perguntava: "Em qual contexto?
  Cerimônia? Medicina? Ensino?" Só então escolhia as palavras certas.

  Este módulo é o intérprete. Ele não apenas mapeia códigos — ele
  entende o contexto FHIR e escolhe a melhor representação canônica.

  — Parábola do Intérprete (inspirada nas assembléias do APIB)

  ---

  ## Responsabilidade

  Transforma recursos FHIR (Observation, Condition, Procedure) recebidos
  de municípios em consultas para o Lexicon Vivo (P1), e converte os
  resultados de volta em codings FHIR canônicos Mindala.

  ## Fluxo de mapeamento

  ```
  recurso FHIR local
       ↓ extract_search_terms/1
  lista de termos candidatos
       ↓ Lexicon.Client.search/2 (P1)
  lista de conceitos ranqueados
       ↓ pick_best_result/1
  conceito com maior confidence_score
       ↓ Validator.apply_threshold/1
  status de mapeamento
       ↓ build_mapping/3
  struct MappingResult
  ```
  """

  alias FhirFlBridge.Lexicon
  alias FhirFlBridge.FHIR.Validator

  @mindala_system_url "https://mindala.health/fhir/CodeSystem/lexicon-vivo"

  @type fhir_resource :: map()
  @type municipality_code :: String.t()

  @type mapping_result :: %{
          original_code: String.t(),
          original_system: String.t(),
          original_display: String.t(),
          canonical_concept_id: String.t() | nil,
          confidence_score: float(),
          lucene_score: float(),
          status: atom(),
          fhir_coding: map() | nil,
          municipality_code: String.t(),
          fhir_resource_type: String.t(),
          requires_human_review: boolean()
        }

  @doc """
  Mapeia um recurso FHIR recebido de um município para o Lexicon Vivo.

  Retorna um `mapping_result` com status, scores e o coding canônico Mindala.

  ## Parâmetros

  - `fhir_resource` — mapa representando o recurso FHIR (Observation, Condition, etc.)
  - `municipality_code` — código IBGE do município de origem (ex: "4205407")

  ## Exemplos

      iex> resource = %{
      ...>   "resourceType" => "Observation",
      ...>   "code" => %{
      ...>     "coding" => [%{"system" => "urn:local:001", "code" => "acup-001"}],
      ...>     "text" => "Acupuntura para dor lombar"
      ...>   }
      ...> }
      iex> FhirFlBridge.FHIR.Mapper.map_resource(resource, "4205407")
      {:ok, %{status: :auto_accepted, confidence_score: 0.91, ...}}
  """
  @spec map_resource(fhir_resource(), municipality_code()) ::
          {:ok, mapping_result()} | {:error, term()}
  def map_resource(fhir_resource, municipality_code) do
    with {:ok, coding} <- extract_primary_coding(fhir_resource),
         {:ok, search_term} <- extract_search_term(fhir_resource),
         {:ok, results} <- Lexicon.client_module().search(search_term, 0.5),
         best_result = pick_best_result(results),
         validation = validate_result(best_result) do
      mapping =
        build_mapping_result(
          coding,
          best_result,
          validation,
          municipality_code,
          Map.get(fhir_resource, "resourceType", "Unknown")
        )

      {:ok, mapping}
    else
      {:error, :no_coding} ->
        {:error, {:invalid_fhir, "Recurso FHIR sem coding"}}

      {:error, :no_search_term} ->
        {:error, {:invalid_fhir, "Impossível extrair termo de busca do recurso"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Extrai o coding primário de um recurso FHIR.

  Prioridade: primeiro coding do array `code.coding[]`.
  """
  @spec extract_primary_coding(fhir_resource()) :: {:ok, map()} | {:error, :no_coding}
  def extract_primary_coding(%{"code" => %{"coding" => [coding | _]}}) do
    {:ok, coding}
  end

  def extract_primary_coding(_), do: {:error, :no_coding}

  @doc """
  Extrai o melhor termo de busca de um recurso FHIR.

  Estratégia:
  1. `code.text` (descrição em linguagem natural) — melhor para busca semântica
  2. `code.coding[0].display` — nome do código
  3. `code.coding[0].code` — código bruto (último recurso)
  """
  @spec extract_search_term(fhir_resource()) :: {:ok, String.t()} | {:error, :no_search_term}
  def extract_search_term(%{"code" => code}) do
    term =
      Map.get(code, "text") ||
        get_in(code, ["coding", Access.at(0), "display"]) ||
        get_in(code, ["coding", Access.at(0), "code"])

    if term && String.length(term) > 0 do
      {:ok, term}
    else
      {:error, :no_search_term}
    end
  end

  def extract_search_term(_), do: {:error, :no_search_term}

  @doc """
  Seleciona o melhor resultado da busca (maior confidence_score).

  Retorna `nil` se a lista estiver vazia.
  """
  @spec pick_best_result(list(map())) :: map() | nil
  def pick_best_result([]), do: nil

  def pick_best_result(results) when is_list(results) do
    Enum.max_by(results, &Map.get(&1, :confidence_score, 0.0))
  end

  # -------------------------------------------------------------------
  # Implementação privada
  # -------------------------------------------------------------------

  defp validate_result(nil) do
    # Nenhum resultado do P1 → score 0.0 → rejected
    Validator.apply_threshold(0.0)
  end

  defp validate_result(result) do
    Validator.apply_threshold(Map.get(result, :confidence_score, 0.0))
  end

  defp build_mapping_result(coding, best_result, validation, municipality_code, resource_type) do
    fhir_coding =
      if best_result && validation.status == :auto_accepted do
        build_fhir_coding(best_result)
      else
        nil
      end

    %{
      original_code: Map.get(coding, "code", ""),
      original_system: Map.get(coding, "system", ""),
      original_display: Map.get(coding, "display", ""),
      canonical_concept_id: if(best_result, do: Map.get(best_result, :concept_id), else: nil),
      confidence_score: if(best_result, do: Map.get(best_result, :confidence_score, 0.0), else: 0.0),
      lucene_score: if(best_result, do: Map.get(best_result, :lucene_score, 0.0), else: 0.0),
      status: validation.status,
      fhir_coding: fhir_coding,
      municipality_code: municipality_code,
      fhir_resource_type: resource_type,
      requires_human_review: validation.requires_human_review
    }
  end

  defp build_fhir_coding(result) do
    %{
      "system" => @mindala_system_url,
      "code" => Map.get(result, :fhir_code, Map.get(result, :concept_id, "")),
      "display" => Map.get(result, :label, ""),
      "tradition" => Map.get(result, :tradition, "unknown")
    }
  end
end
