defmodule FhirFlBridge.FHIR.Bridge do
  @moduledoc """
  # Parábola da Ponte Viva

  Havia uma ponte de madeira sobre um rio turvo. Certa vez, uma enchente
  a derrubou. Os aldeões reconstruíram a ponte — mas desta vez, plantaram
  árvores nas margens. Com o tempo, as raízes seguraram a terra, as
  copas filtraram a chuva, e o rio ficou mais manso. A ponte deixou de
  ser apenas uma estrutura — tornou-se parte da vida do rio.

  Este GenServer é a ponte viva do P2. Ele não apenas traduz recursos
  FHIR — ele aprende com cada mapeamento, mantém estado das filas e
  notifica o Orchestrador quando novos dados chegam.

  — Parábola da Ponte Viva (tradição dos ribeirinhos do Pantanal)

  ---

  ## Responsabilidade

  GenServer que gerencia o estado das operações de mapeamento FHIR.
  É o ponto de entrada para todos os recursos FHIR recebidos de municípios.

  ## Estado interno

  ```elixir
  %{
    pending_review_count: integer(),    # Mapeamentos aguardando Guardião
    auto_accepted_today: integer(),     # Mapeamentos auto-aceitos hoje
    last_mapping_at: DateTime.t() | nil
  }
  ```

  ## Interface pública

  - `map_resource/2` — mapeia um recurso FHIR e persiste no PostgreSQL
  - `get_pending_count/0` — retorna contagem de mapeamentos pendentes
  - `stats/0` — retorna estatísticas do Bridge
  """

  use GenServer
  require Logger

  alias FhirFlBridge.FHIR.Mapper
  alias FhirFlBridge.Repo
  alias FhirFlBridge.Repo.Schemas.ConceptMapping

  import Ecto.Query, only: [from: 2]

  @name __MODULE__

  # -------------------------------------------------------------------
  # API pública
  # -------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, initial_state(), name: @name)
  end

  @doc """
  Mapeia um recurso FHIR para o Lexicon Vivo e persiste o resultado.

  Esta função é assíncrona (`cast`) para não bloquear o controller HTTP.
  O resultado é persistido no banco e eventos são emitidos via PubSub.

  Para obter o resultado de forma síncrona (ex: em testes), use `map_resource_sync/2`.
  """
  @spec map_resource(map(), String.t()) :: :ok
  def map_resource(fhir_resource, municipality_code) do
    GenServer.cast(@name, {:map_resource, fhir_resource, municipality_code})
  end

  @doc """
  Versão síncrona de `map_resource/2`. Aguarda o resultado do mapeamento.

  Retorna `{:ok, mapping_attrs}` ou `{:error, reason}`.
  Útil para o controller HTTP retornar o resultado imediatamente.
  """
  @spec map_resource_sync(map(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def map_resource_sync(fhir_resource, municipality_code) do
    GenServer.call(@name, {:map_resource_sync, fhir_resource, municipality_code}, 15_000)
  end

  @doc "Retorna a contagem de mapeamentos pendentes de revisão"
  @spec get_pending_count() :: integer()
  def get_pending_count do
    GenServer.call(@name, :get_pending_count)
  end

  @doc "Retorna estatísticas de operação do Bridge"
  @spec stats() :: map()
  def stats do
    GenServer.call(@name, :stats)
  end

  # -------------------------------------------------------------------
  # Callbacks GenServer
  # -------------------------------------------------------------------

  @impl GenServer
  def init(state) do
    Logger.info("[Bridge] FHIR Bridge iniciado — aguardando recursos municipais")
    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:map_resource, fhir_resource, municipality_code}, state) do
    case do_map_and_persist(fhir_resource, municipality_code) do
      {:ok, mapping_attrs} ->
        new_state = update_stats(state, mapping_attrs.status)
        broadcast_mapping_event(mapping_attrs)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("[Bridge] Falha ao mapear recurso: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_call({:map_resource_sync, fhir_resource, municipality_code}, _from, state) do
    case do_map_and_persist(fhir_resource, municipality_code) do
      {:ok, mapping_attrs} = result ->
        new_state = update_stats(state, mapping_attrs.status)
        broadcast_mapping_event(mapping_attrs)
        {:reply, result, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_call(:get_pending_count, _from, state) do
    count =
      Repo.aggregate(
        from(m in ConceptMapping, where: m.status == "pending_review"),
        :count,
        :id
      )

    {:reply, count, state}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    {:reply, Map.put(state, :uptime_ms, System.monotonic_time(:millisecond)), state}
  end

  # -------------------------------------------------------------------
  # Implementação privada
  # -------------------------------------------------------------------

  defp initial_state do
    %{
      pending_review_count: 0,
      auto_accepted_today: 0,
      last_mapping_at: nil,
      started_at: DateTime.utc_now()
    }
  end

  defp do_map_and_persist(fhir_resource, municipality_code) do
    with {:ok, mapping_attrs} <- Mapper.map_resource(fhir_resource, municipality_code) do
      # Persiste no PostgreSQL
      changeset = ConceptMapping.changeset(%ConceptMapping{}, mapping_attrs_to_db(mapping_attrs))

      case Repo.insert(changeset) do
        {:ok, _record} ->
          Logger.info(
            "[Bridge] Mapeamento #{mapping_attrs.status} — #{mapping_attrs.original_code} " <>
              "→ #{mapping_attrs.canonical_concept_id || "sem match"} " <>
              "(score: #{mapping_attrs.confidence_score})"
          )

          {:ok, mapping_attrs}

        {:error, changeset} ->
          {:error, {:db_error, changeset}}
      end
    end
  end

  defp mapping_attrs_to_db(attrs) do
    %{
      original_code: attrs.original_code,
      original_system: attrs.original_system,
      canonical_concept_id: attrs.canonical_concept_id,
      confidence_score: attrs.confidence_score,
      lucene_score: attrs.lucene_score,
      status: Atom.to_string(attrs.status),
      municipality_code: attrs.municipality_code,
      fhir_resource_type: attrs.fhir_resource_type,
      mapped_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp update_stats(state, :auto_accepted) do
    %{
      state
      | auto_accepted_today: state.auto_accepted_today + 1,
        last_mapping_at: DateTime.utc_now()
    }
  end

  defp update_stats(state, :pending_review) do
    %{
      state
      | pending_review_count: state.pending_review_count + 1,
        last_mapping_at: DateTime.utc_now()
    }
  end

  defp update_stats(state, _status) do
    %{state | last_mapping_at: DateTime.utc_now()}
  end

  defp broadcast_mapping_event(mapping_attrs) do
    Phoenix.PubSub.broadcast(
      FhirFlBridge.PubSub,
      "fhir:mappings",
      {:new_mapping, mapping_attrs}
    )
  end
end
