defmodule FhirFlBridge.FL.Orchestrator do
  @moduledoc """
  # Parábola do Plantador de Estações

  Um agricultor sábio não plantava quando tinha vontade — plantava
  quando a terra estava pronta. Ele observava o céu, o solo, as chuvas.
  Quando as condições se alinhavam, ele chamava os trabalhadores das
  aldeias vizinhas. Cada um trazia sua enxada, seu conhecimento,
  seu pedaço de terra. E ao fim da colheita, todos dividiam os frutos.

  Este GenServer observa as condições (mapeamentos acumulados,
  participantes disponíveis) e decide quando iniciar uma colheita
  federada. O modelo global é o fruto dividido entre todos.

  — Parábola do Plantador (sabedoria dos agricultores Kaiabi do Xingu)

  ---

  ## Responsabilidade

  Coordenador central das rodadas de Federated Learning.

  Responsabilidades:
  1. Monitorar acumulação de novos mapeamentos confirmados (P1)
  2. Decidir quando iniciar uma nova rodada FL
  3. Calcular confidence_weight de cada participante via P1
  4. Delegar o lifecycle da rodada ao RoundWorker via RoundSupervisor
  5. Receber eventos de conclusão e atualizar o estado global

  ## Estado interno

  ```elixir
  %{
    current_model_version: integer(),
    pending_mappings_count: integer(),
    active_round_ids: [String.t()],
    last_round_at: DateTime.t() | nil,
    total_rounds_completed: integer()
  }
  ```
  """

  use GenServer
  require Logger

  alias FhirFlBridge.FL.RoundSupervisor
  alias FhirFlBridge.Repo
  alias FhirFlBridge.Repo.Schemas.{FLRound, FLParticipant, ConceptMapping}

  import Ecto.Query

  @name __MODULE__
  # Inicia rodada a cada 10 novos mapeamentos auto_accepted (configurável)
  @mappings_per_round 10

  # -------------------------------------------------------------------
  # API pública
  # -------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, initial_state(), name: @name)
  end

  @doc """
  Notifica o Orchestrator que um novo mapeamento foi confirmado.
  Pode disparar uma rodada FL se o threshold for atingido.
  """
  @spec notify_new_mapping(map()) :: :ok
  def notify_new_mapping(mapping_attrs) do
    GenServer.cast(@name, {:new_mapping, mapping_attrs})
  end

  @doc """
  Inicia uma rodada FL manualmente com participantes explícitos.

  Usado pela API REST (`POST /api/v1/fl/rounds`).
  """
  @spec start_manual_round(list(map())) ::
          {:ok, String.t()} | {:error, term()}
  def start_manual_round(participants) when is_list(participants) do
    GenServer.call(@name, {:start_manual_round, participants}, 15_000)
  end

  @doc "Retorna o estado atual do Orchestrator"
  @spec get_status() :: map()
  def get_status do
    GenServer.call(@name, :get_status)
  end

  # -------------------------------------------------------------------
  # Callbacks GenServer
  # -------------------------------------------------------------------

  @impl GenServer
  def init(state) do
    Logger.info("[Orchestrator] FL Orchestrator iniciado — modelo v#{state.current_model_version}")

    # Subscreve a eventos de conclusão de rodadas
    Phoenix.PubSub.subscribe(FhirFlBridge.PubSub, "fl:rounds")

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:new_mapping, mapping_attrs}, state) do
    new_count = state.pending_mappings_count + 1
    new_state = %{state | pending_mappings_count: new_count}

    Logger.debug("[Orchestrator] Mapeamento #{mapping_attrs.status} recebido (acumulado: #{new_count})")

    # Verifica se deve iniciar rodada automática
    if new_count >= @mappings_per_round do
      Logger.info("[Orchestrator] Threshold atingido (#{new_count} mapeamentos) — iniciando rodada FL automática")
      {:noreply, maybe_start_auto_round(new_state)}
    else
      {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_call({:start_manual_round, participants_input}, _from, state) do
    case build_and_start_round(participants_input, state.current_model_version) do
      {:ok, round_id} ->
        new_state = %{
          state
          | active_round_ids: [round_id | state.active_round_ids],
            pending_mappings_count: 0
        }

        {:reply, {:ok, round_id}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call(:get_status, _from, state) do
    {:reply, state, state}
  end

  # Recebe evento de conclusão via PubSub
  @impl GenServer
  def handle_info({:round_completed, round_id, _result}, state) do
    Logger.info("[Orchestrator] Rodada #{round_id} concluída — incrementando modelo para v#{state.current_model_version + 1}")

    new_state = %{
      state
      | current_model_version: state.current_model_version + 1,
        active_round_ids: List.delete(state.active_round_ids, round_id),
        last_round_at: DateTime.utc_now(),
        total_rounds_completed: state.total_rounds_completed + 1
    }

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info({:round_failed, round_id, reason}, state) do
    Logger.warning("[Orchestrator] Rodada #{round_id} falhou: #{reason}")

    new_state = %{
      state
      | active_round_ids: List.delete(state.active_round_ids, round_id)
    }

    {:noreply, new_state}
  end

  # Ignora outros eventos PubSub
  def handle_info(_event, state), do: {:noreply, state}

  # -------------------------------------------------------------------
  # Implementação privada
  # -------------------------------------------------------------------

  defp initial_state do
    %{
      current_model_version: 1,
      pending_mappings_count: 0,
      active_round_ids: [],
      last_round_at: nil,
      total_rounds_completed: 0,
      started_at: DateTime.utc_now()
    }
  end

  defp maybe_start_auto_round(state) do
    # Busca participantes disponíveis no banco (mapeamentos recentes por município)
    participants = load_available_participants()

    case build_and_start_round(participants, state.current_model_version) do
      {:ok, round_id} ->
        %{
          state
          | active_round_ids: [round_id | state.active_round_ids],
            pending_mappings_count: 0
        }

      {:error, reason} ->
        Logger.warning("[Orchestrator] Falha ao iniciar rodada automática: #{inspect(reason)}")
        state
    end
  end

  defp build_and_start_round(participants_input, model_version) do
    round_id     = UUID.uuid4()
    participants = Enum.map(participants_input, &normalize_participant/1)

    with {:ok, _round}                  <- create_fl_round(round_id, model_version, length(participants)),
         {:ok, participants_w_weights}  <- enrich_with_confidence_weights(participants),
         {:ok, _}                       <- create_fl_participants(round_id, participants_w_weights),
         {:ok, _pid}                    <- RoundSupervisor.start_round(round_id, participants_w_weights, model_version) do
      {:ok, round_id}
    else
      {:error, reason} -> {:error, reason}
      other            -> {:error, {:unexpected, other}}
    end
  end

  # Normaliza participant: aceita chaves string (JSON) ou atom (Elixir)
  defp normalize_participant(p) do
    %{
      municipality_code: Map.get(p, :municipality_code) || Map.get(p, "municipality_code", ""),
      node_url:          Map.get(p, :node_url)          || Map.get(p, "node_url", ""),
      confidence_weight: Map.get(p, :confidence_weight) || Map.get(p, "confidence_weight", 0.5)
    }
  end

  # Busca municípios com mapeamentos recentes e monta lista de participantes
  defp load_available_participants do
    Repo.all(
      from cm in ConceptMapping,
        where: cm.status == "auto_accepted",
        group_by: cm.municipality_code,
        select: %{
          municipality_code: cm.municipality_code,
          avg_confidence: avg(cm.confidence_score),
          mapping_count: count(cm.id)
        }
    )
    |> Enum.map(fn row ->
      %{
        municipality_code: row.municipality_code,
        node_url: "http://#{row.municipality_code}-node:8080",
        confidence_weight: row.avg_confidence || 0.5
      }
    end)
  end

  # Enriquece participantes com confidence_weight calculado via P1
  defp enrich_with_confidence_weights(participants) do
    enriched =
      Enum.map(participants, fn p ->
        weight = Map.get(p, :confidence_weight) || calculate_weight_from_db(p.municipality_code)
        Map.put(p, :confidence_weight, weight)
      end)

    {:ok, enriched}
  end

  defp calculate_weight_from_db(municipality_code) do
    result =
      Repo.one(
        from cm in ConceptMapping,
          where: cm.municipality_code == ^municipality_code and cm.status == "auto_accepted",
          select: avg(cm.confidence_score)
      )

    result || 0.5
  end

  defp create_fl_round(round_id, model_version, participant_count) do
    %FLRound{}
    |> FLRound.changeset(%{
      id: round_id,
      model_version: model_version,
      total_participants: participant_count,
      status: "pending",
      aggregation_strategy: "weighted_fedavg",
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert()
  end

  defp create_fl_participants(round_id, participants) do
    results =
      Enum.map(participants, fn p ->
        %FLParticipant{}
        |> FLParticipant.changeset(%{
          fl_round_id:       round_id,
          municipality_code: p.municipality_code,
          node_url:          Map.get(p, :node_url, ""),
          confidence_weight: p.confidence_weight,
          status:            "invited"
        })
        |> Repo.insert()
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors),
      do: {:ok, results},
      else: {:error, {:participant_insert_failed, errors}}
  end
end
