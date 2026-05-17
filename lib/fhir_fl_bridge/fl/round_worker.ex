defmodule FhirFlBridge.FL.RoundWorker do
  @moduledoc """
  # Parábola do Correio das Aldeias

  Havia um jovem correio que percorria aldeias remotas levando e trazendo
  mensagens. Cada viagem era uma rodada: ele partia, distribuía as
  cartas, esperava as respostas, coletava tudo e voltava ao centro.
  Se uma aldeia não respondia no prazo, ele registrava a ausência e
  continuava. A mensagem final era menor, mas ainda útil.

  Este GenServer é aquele jovem correio. Cada instância é uma rodada
  de treinamento federado — vai, distribui, espera, coleta e agrega.

  — Parábola do Correio (tradição oral das aldeias Pataxó da Bahia)

  ---

  ## Estados de uma rodada

  ```
  :pending
    → :distributing   (enviando modelo aos nós municipais)
    → :collecting     (aguardando gradientes dos nós)
    → :aggregating    (rodando FedAvg ponderado)
    → :completed      (θ_global atualizado no banco)
    | :failed         (timeout ou erro crítico)
  ```

  ## Tolerância a falhas

  - Nós com timeout → marcados como `:timeout`, rodada prossegue se
    `min_participants` ainda estiverem respondendo
  - Falha no Aggregator → rodada falha, Orchestrator é notificado
  - Crash do RoundWorker → DynamicSupervisor não reinicia (`:temporary`)
    → Orchestrator detecta via monitor e atualiza banco
  """

  use GenServer
  require Logger

  alias FhirFlBridge.FL.Aggregator
  alias FhirFlBridge.Repo
  alias FhirFlBridge.Repo.Schemas.FLRound

  @default_timeout_ms 300_000  # 5 minutos
  @collect_poll_ms 5_000       # Polling a cada 5s para simular coleta

  # -------------------------------------------------------------------
  # API pública
  # -------------------------------------------------------------------

  def start_link(%{round_id: round_id} = args) do
    GenServer.start_link(__MODULE__, args, name: via(round_id))
  end

  defp via(round_id), do: {:via, Registry, {FhirFlBridge.RoundRegistry, round_id}}

  @doc "Notifica que um participante submeteu seus gradientes"
  def submit_gradients(round_id, municipality_code, gradients) do
    GenServer.cast(via(round_id), {:gradient_submitted, municipality_code, gradients})
  end

  @doc "Retorna o estado atual da rodada"
  def get_state(round_id) do
    GenServer.call(via(round_id), :get_state)
  end

  # -------------------------------------------------------------------
  # Callbacks GenServer
  # -------------------------------------------------------------------

  @impl GenServer
  def init(%{round_id: round_id, participants: participants, model_version: model_version}) do
    timeout_ms =
      Application.get_env(:fhir_fl_bridge, :fl_config, [])
      |> Keyword.get(:round_timeout_ms, @default_timeout_ms)

    Process.send_after(self(), :round_timeout, timeout_ms)

    state = %{
      round_id:     round_id,
      model_version: model_version,
      status:       :pending,
      participants:  init_participants(participants, round_id),
      started_at:   DateTime.utc_now(),
      timeout_ms:   timeout_ms
    }

    Logger.info("[RoundWorker] Rodada #{round_id} inicializada com #{length(participants)} participantes")
    send(self(), :start_distribution)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:start_distribution, state) do
    Logger.info("[RoundWorker] Rodada #{state.round_id} — iniciando distribuição do modelo v#{state.model_version}")

    # Atualiza banco: status → distributing
    update_round_status(state.round_id, "distributing")

    # Simula distribuição do modelo para cada nó
    # Em produção: envia via HTTP para os nós Python/Flower
    updated_participants = distribute_model_to_participants(state.participants, state.model_version)

    new_state = %{state | status: :collecting, participants: updated_participants}

    # Agenda polling para simular coleta de gradientes
    Process.send_after(self(), :check_collection, @collect_poll_ms)

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:check_collection, state) do
    submitted_count = count_submitted(state.participants)
    total = length(state.participants)

    Logger.info("[RoundWorker] Rodada #{state.round_id} — #{submitted_count}/#{total} gradientes recebidos")

    min_participants =
      Application.get_env(:fhir_fl_bridge, :fl_config, [])
      |> Keyword.get(:min_participants, 2)

    if submitted_count >= min_participants do
      send(self(), :aggregate)
      {:noreply, %{state | status: :aggregating}}
    else
      # Aguarda mais
      Process.send_after(self(), :check_collection, @collect_poll_ms)
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(:aggregate, state) do
    Logger.info("[RoundWorker] Rodada #{state.round_id} — iniciando agregação FedAvg ponderada")
    update_round_status(state.round_id, "aggregating")

    try do
      case Aggregator.weighted_fedavg(state.participants) do
        {:ok, result} ->
          persist_aggregation_result(state.round_id, result)

          Logger.info(
            "[RoundWorker] Rodada #{state.round_id} CONCLUÍDA — " <>
              "#{result.effective_participants} participantes, " <>
              "peso total: #{Float.round(result.total_weight, 4)}"
          )

          notify_orchestrator({:round_completed, state.round_id, result})
          {:stop, :normal, %{state | status: :completed}}

        {:error, :insufficient_participants} ->
          Logger.warning("[RoundWorker] Rodada #{state.round_id} falhou: participantes insuficientes")
          fail_round(state.round_id, "insufficient_participants")
          {:stop, :normal, %{state | status: :failed}}
      end
    rescue
      e ->
        Logger.error(
          "[RoundWorker] CRASH em :aggregate — #{Exception.message(e)}\n" <>
            Exception.format(:error, e, __STACKTRACE__)
        )
        fail_round(state.round_id, "aggregation_crash")
        {:stop, :normal, %{state | status: :failed}}
    end
  end

  @impl GenServer
  def handle_info(:round_timeout, state) do
    Logger.warning("[RoundWorker] Rodada #{state.round_id} — TIMEOUT após #{state.timeout_ms}ms")

    # Marca participantes sem resposta como timeout
    updated_participants =
      Enum.map(state.participants, fn p ->
        if p.status == :training, do: %{p | status: :timeout}, else: p
      end)

    timeout_state = %{state | participants: updated_participants}

    # Tenta agregar com quem respondeu
    send(self(), :aggregate)
    {:noreply, timeout_state}
  end

  @impl GenServer
  def handle_cast({:gradient_submitted, municipality_code, gradients}, state) do
    updated_participants =
      Enum.map(state.participants, fn p ->
        if p.municipality_code == municipality_code do
          %{p | status: :submitted, local_gradients: gradients, submitted_at: DateTime.utc_now() |> DateTime.truncate(:second)}
        else
          p
        end
      end)

    {:noreply, %{state | participants: updated_participants}}
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  # -------------------------------------------------------------------
  # Implementação privada
  # -------------------------------------------------------------------

  defp init_participants(participants, round_id) do
    Enum.map(participants, fn p ->
      Map.merge(p, %{round_id: round_id, status: :invited, local_gradients: nil, submitted_at: nil})
    end)
  end

  defp distribute_model_to_participants(participants, model_version) do
    p2_base = System.get_env("P2_INTERNAL_URL", "http://p2:4001")

    Enum.map(participants, fn p ->
      node_url     = Map.get(p, :node_url, "")
      round_id     = Map.get(p, :round_id, to_string(model_version))
      callback_url = "#{p2_base}/api/v1/fl/rounds/#{round_id}/gradients"

      if node_url != "" do
        payload = Jason.encode!(%{
          round_id:      round_id,
          model_weights: %{"acupuntura" => 0.5, "fitoterapia" => 0.5,
                           "homeopatia" => 0.5, "meditacao" => 0.5},
          callback_url:  callback_url
        })

        client = Tesla.client([
          {Tesla.Middleware.Headers, [{"content-type", "application/json"}]},
          {Tesla.Middleware.Timeout, timeout: 10_000}
        ], Tesla.Adapter.Hackney)

        case Tesla.post(client, node_url <> "/train", payload) do
          {:ok, %{status: s}} when s in [200, 202] ->
            Logger.info("[RoundWorker] → #{p.municipality_code} @ #{node_url} — modelo enviado")
            %{p | status: :training}

          {:ok, %{status: s}} ->
            Logger.warning("[RoundWorker] Nó #{p.municipality_code} respondeu HTTP #{s}")
            %{p | status: :training}

          {:error, reason} ->
            Logger.warning("[RoundWorker] Falha ao contatar #{p.municipality_code}: #{inspect(reason)}")
            %{p | status: :timeout}
        end
      else
        Logger.warning("[RoundWorker] Nó #{p.municipality_code} sem node_url — timeout")
        %{p | status: :timeout}
      end
    end)
  end

  defp count_submitted(participants) do
    Enum.count(participants, &(&1.status == :submitted))
  end

  defp update_round_status(round_id, status) do
    case Repo.get(FLRound, round_id) do
      nil ->
        Logger.error("[RoundWorker] ERRO: Rodada #{round_id} não encontrada no banco ao atualizar status para '#{status}'")

      round ->
        case round |> Ecto.Changeset.change(status: status) |> Repo.update() do
          {:ok, _} ->
            Logger.info("[RoundWorker] Rodada #{round_id} status atualizado: #{status}")
          {:error, changeset} ->
            Logger.error("[RoundWorker] ERRO ao atualizar status para '#{status}': #{inspect(changeset.errors)}")
        end
    end
  end

  defp persist_aggregation_result(round_id, result) do
    case Repo.get(FLRound, round_id) do
      nil ->
        Logger.warning("[RoundWorker] persist: rodada #{round_id} não encontrada")

      round ->
        changes = %{
          status:                 "completed",
          global_weights:         result.global_weights,
          completed_participants:  result.effective_participants,
          completed_at:           DateTime.utc_now() |> DateTime.truncate(:second)
        }

        case round |> Ecto.Changeset.change(changes) |> Repo.update() do
          {:ok, _} ->
            Logger.info("[RoundWorker] θ_global persistido para rodada #{round_id}")

          {:error, cs} ->
            Logger.error("[RoundWorker] Falha ao persistir rodada #{round_id}: #{inspect(cs.errors)}")
        end
    end
  end

  defp fail_round(round_id, reason) do
    update_round_status(round_id, "failed")

    Phoenix.PubSub.broadcast(
      FhirFlBridge.PubSub,
      "fl:rounds",
      {:round_failed, round_id, reason}
    )
  end

  defp notify_orchestrator(event) do
    Phoenix.PubSub.broadcast(FhirFlBridge.PubSub, "fl:rounds", event)
  end
end
