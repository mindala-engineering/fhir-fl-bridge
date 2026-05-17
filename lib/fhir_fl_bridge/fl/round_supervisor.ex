defmodule FhirFlBridge.FL.RoundSupervisor do
  @moduledoc """
  # Parábola do Regente e os Músicos

  Um regente de orquestra não toca nenhum instrumento. Mas sem ele,
  cada músico toca em seu próprio tempo, em seu próprio ritmo.
  O regente não controla os músicos — ele cria as condições para que
  todos toquem juntos, cada um com sua voz única, produzindo algo
  que nenhum poderia produzir sozinho.

  Este DynamicSupervisor é o estante de partituras: ele não rege,
  mas garante que cada RoundWorker tenha o que precisa para entrar
  e sair de cena com segurança.

  — Parábola do Regente (inspirada na tradição das bandas de música do interior de Minas)

  ---

  ## Responsabilidade

  DynamicSupervisor que gerencia o ciclo de vida de `RoundWorker`s.
  Cada rodada FL ativa é um processo filho independente.

  Propriedades:
  - `:temporary` — RoundWorkers não são reiniciados automaticamente após falha
    (uma rodada falha não deve ser retomada automaticamente; o Orchestrator decide)
  - Um processo filho por `round_id`
  """

  use DynamicSupervisor

  require Logger

  @name __MODULE__

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: @name)
  end

  @impl DynamicSupervisor
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Inicia um RoundWorker para uma rodada FL específica.

  ## Parâmetros

  - `round_id` — UUID da rodada
  - `participants` — lista de participantes convocados
  - `model_version` — versão atual do modelo global
  """
  def start_round(round_id, participants, model_version) do
    child_spec = %{
      id: round_worker_id(round_id),
      start:
        {FhirFlBridge.FL.RoundWorker, :start_link,
         [
           %{
             round_id: round_id,
             participants: participants,
             model_version: model_version
           }
         ]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(@name, child_spec) do
      {:ok, pid} ->
        Logger.info("[RoundSupervisor] Rodada #{round_id} iniciada (pid: #{inspect(pid)})")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.warning("[RoundSupervisor] Rodada #{round_id} já está ativa")
        {:already_started, pid}

      {:error, reason} ->
        Logger.error("[RoundSupervisor] Falha ao iniciar rodada #{round_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Retorna a lista de rodadas ativas"
  def active_rounds do
    DynamicSupervisor.which_children(@name)
    |> Enum.map(fn {id, pid, _type, _modules} -> %{id: id, pid: pid} end)
  end

  @doc "Conta o número de rodadas ativas"
  def active_count do
    DynamicSupervisor.count_children(@name).active
  end

  defp round_worker_id(round_id), do: :"round_worker_#{round_id}"
end
