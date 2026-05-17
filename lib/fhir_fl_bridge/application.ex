defmodule FhirFlBridge.Application do
  @moduledoc """
  # Parábola da Árvore e dos Galhos

  Uma árvore foi questionada por um jardineiro: "Por que você deixa seus
  galhos crescerem em direções tão diferentes?" A árvore respondeu: "Cada
  galho busca sua própria luz. Se um galho cair durante a tempestade, os
  outros continuam buscando. É assim que a árvore sobrevive ao inverno."

  Este módulo é o tronco da árvore OTP do P2. Cada processo filho é um
  galho autônomo — a queda de um não compromete os outros.

  — Parábola da Árvore (sabedoria dos povos Guarani do sul do Brasil)

  ---

  ## Supervision Tree

  ```
  FhirFlBridge.Application (Supervisor, strategy: :one_for_one)
  ├── FhirFlBridge.Repo              — persistência PostgreSQL
  ├── FhirFlBridgeWeb.Endpoint       — servidor HTTP Phoenix
  ├── FhirFlBridge.PubSub            — pub/sub para LiveView
  ├── FhirFlBridge.FHIR.Bridge       — GenServer: bridge FHIR ↔ Lexicon
  └── FhirFlBridge.FL.Orchestrator   — GenServer: orquestrador FL
      └── FhirFlBridge.FL.RoundSupervisor — DynamicSupervisor por rodada
  ```

  ## Justificativa `one_for_one`

  Bridge FHIR e Orchestrador FL são responsabilidades independentes.
  Uma falha no Bridge (ex: P1 indisponível) não deve interromper rodadas
  FL já em andamento. A estratégia `:one_for_one` garante essa isolação.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Repositório Ecto — primeiro filho: outros dependem do banco
      FhirFlBridge.Repo,

      # Registry para RoundWorkers (necessário para {:via, Registry, ...})
      {Registry, keys: :unique, name: FhirFlBridge.RoundRegistry},

      # PubSub — necessário para Phoenix LiveView
      {Phoenix.PubSub, name: FhirFlBridge.PubSub},

      # Endpoint Phoenix (HTTP server)
      FhirFlBridgeWeb.Endpoint,

      # Bridge FHIR — GenServer que gerencia mapeamentos
      FhirFlBridge.FHIR.Bridge,

      # Supervisor dinâmico para rodadas FL (deve subir ANTES do Orchestrator)
      FhirFlBridge.FL.RoundSupervisor,

      # Orquestrador FL — GenServer principal
      FhirFlBridge.FL.Orchestrator
    ]

    opts = [strategy: :one_for_one, name: FhirFlBridge.Supervisor]

    Supervisor.start_link(children, opts)
  end

  # Phoenix requer este callback para hot reloading em desenvolvimento
  @impl true
  def config_change(changed, _new, removed) do
    FhirFlBridgeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
