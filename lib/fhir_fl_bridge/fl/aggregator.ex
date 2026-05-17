defmodule FhirFlBridge.FL.Aggregator do
  @moduledoc """
  # Parábola das Vozes do Conselho

  Num conselho de anciãos, cada voz tinha um peso diferente — não pela
  idade, mas pela profundidade do conhecimento de cada ancião sobre o
  assunto em debate. O ancião que viveu aquela situação, que estudou
  aquele território, que praticou aquela medicina — sua voz pesava mais.
  Não por imposição, mas por consenso de todos.

  Este módulo implementa exatamente esse conselho. Cada nó municipal
  é um ancião. Seu peso na decisão final (o modelo global) é determinado
  pelo quanto seus conceitos são confiáveis — medido pelo Lexicon Vivo.

  — Parábola do Conselho (tradição dos Conselhos de Anciãos Xavante)

  ---

  ## Algoritmo: FedAvg Ponderado por Confiança Epistêmica

  ### FedAvg Clássico (McMahan et al., 2017)

  ```
  θ_global = Σ(n_i / n_total * θ_i)
  ```

  Onde `n_i` é o número de amostras locais do nó `i`.

  ### FedAvg Ponderado Mindala

  ```
  w_i = confidence_weight_i ∈ [0.0, 1.0]
  θ_global = Σ(w_i * θ_i) / Σ(w_i)
  ```

  Onde `confidence_weight_i` é o score médio de confiança dos mapeamentos
  terminológicos do município `i`, derivado do Lexicon Vivo (P1).

  ### Justificativa

  Um município que usa terminologia confiável (validada pelo Guardião
  Epistêmico) contribui com dados semanticamente consistentes. Dar mais
  peso a esses dados melhora a qualidade do modelo global — é tanto
  incentivo para boas práticas quanto proteção epistêmica.
  """

  require Logger

  @type participant :: %{
          municipality_code: String.t(),
          confidence_weight: float(),
          local_gradients: map(),
          samples_count: integer(),
          status: atom()
        }

  @type aggregation_result :: %{
          global_weights: map(),
          effective_participants: integer(),
          total_weight: float(),
          aggregation_strategy: atom(),
          per_participant_contribution: list(map())
        }

  @doc """
  Executa FedAvg ponderado pelo confidence_weight dos participantes.

  ## Parâmetros

  - `participants` — lista de participantes com gradientes e pesos

  ## Retorna

  `{:ok, aggregation_result}` com o vetor de pesos globais θ_global,
  ou `{:error, :insufficient_participants}` se não houver participantes
  com gradientes válidos.

  ## Exemplos

      iex> participants = [
      ...>   %{municipality_code: "4205407", confidence_weight: 0.91,
      ...>     local_gradients: %{"layer_1" => [0.1, 0.2, 0.3]}, samples_count: 100, status: :submitted},
      ...>   %{municipality_code: "4202404", confidence_weight: 0.72,
      ...>     local_gradients: %{"layer_1" => [0.4, 0.5, 0.6]}, samples_count: 80, status: :submitted}
      ...> ]
      iex> FhirFlBridge.FL.Aggregator.weighted_fedavg(participants)
      {:ok, %{global_weights: %{"layer_1" => [...]}, ...}}
  """
  @spec weighted_fedavg(list(participant())) ::
          {:ok, aggregation_result()} | {:error, :insufficient_participants}
  def weighted_fedavg(participants) when is_list(participants) do
    # Filtra apenas participantes que enviaram gradientes
    valid = Enum.filter(participants, &(&1.status == :submitted && &1.local_gradients != nil))

    if Enum.empty?(valid) do
      Logger.warning("[Aggregator] Nenhum participante com gradientes válidos para agregar")
      {:error, :insufficient_participants}
    else
      do_aggregate(valid)
    end
  end

  @doc """
  Calcula o peso de contribuição normalizado de cada participante.

  Retorna lista de `%{municipality_code, raw_weight, normalized_weight}`.
  """
  @spec compute_weights(list(participant())) :: list(map())
  def compute_weights(participants) do
    total_weight = Enum.sum(Enum.map(participants, & &1.confidence_weight))

    Enum.map(participants, fn p ->
      normalized = if total_weight > 0, do: p.confidence_weight / total_weight, else: 0.0

      %{
        municipality_code: p.municipality_code,
        raw_weight:         p.confidence_weight,
        normalized_weight:  normalized,
        samples_count:      Map.get(p, :samples_count, 0)
      }
    end)
  end

  # -------------------------------------------------------------------
  # Implementação privada
  # -------------------------------------------------------------------

  defp do_aggregate(valid_participants) do
    total_weight = Enum.sum(Enum.map(valid_participants, & &1.confidence_weight))

    Logger.info(
      "[Aggregator] Agregando #{length(valid_participants)} participantes " <>
        "(peso total: #{Float.round(total_weight, 4)})"
    )

    # Coleta todas as chaves de camadas presentes nos gradientes
    all_layer_keys =
      valid_participants
      |> Enum.flat_map(&Map.keys(&1.local_gradients))
      |> Enum.uniq()

    # Agrega cada camada separadamente
    global_weights =
      Map.new(all_layer_keys, fn layer_key ->
        aggregated_layer = aggregate_layer(valid_participants, layer_key, total_weight)
        {layer_key, aggregated_layer}
      end)

    per_participant_contribution = compute_weights(valid_participants)

    result = %{
      global_weights: global_weights,
      effective_participants: length(valid_participants),
      total_weight: total_weight,
      aggregation_strategy: :weighted_fedavg,
      per_participant_contribution: per_participant_contribution
    }

    {:ok, result}
  end

  # Agrega uma camada específica do modelo usando média ponderada
  defp aggregate_layer(participants, layer_key, total_weight) do
    participants
    |> Enum.filter(&Map.has_key?(&1.local_gradients, layer_key))
    |> Enum.reduce(nil, fn participant, acc ->
      layer_values = Map.get(participant.local_gradients, layer_key)
      weight = participant.confidence_weight / total_weight

      case {acc, layer_values} do
        {nil, values} when is_list(values) ->
          # Primeira iteração: multiplica por peso
          Enum.map(values, &(&1 * weight))

        {accumulated, values} when is_list(values) and is_list(accumulated) ->
          # Iterações seguintes: soma ponderada
          Enum.zip_with(accumulated, values, fn acc_val, new_val ->
            acc_val + new_val * weight
          end)

        _ ->
          acc
      end
    end)
  end
end
