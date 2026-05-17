defmodule FhirFlBridgeWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Health check (sem autenticação)
  scope "/", FhirFlBridgeWeb do
    get "/health", HealthController, :index
  end

  # API v1
  scope "/api/v1", FhirFlBridgeWeb do
    pipe_through :api

    # --- Bridge FHIR ---
    scope "/fhir" do
      # Mapear um recurso FHIR
      post "/map", FhirController, :map_resource

      # Listar mapeamentos (com filtro por status)
      get "/mappings", FhirController, :list_mappings

      # Obter um mapeamento específico
      get "/mappings/:id", FhirController, :show_mapping

      # Guardião Epistêmico: revisar mapeamento
      patch "/mappings/:id/review", FhirController, :review_mapping

      # Thresholds vigentes
      get "/thresholds", FhirController, :thresholds
    end

    # --- Federated Learning ---
    scope "/fl" do
      # Iniciar rodada FL manualmente
      post "/rounds", FlController, :start_round

      # Listar rodadas
      get "/rounds", FlController, :list_rounds

      # Status de uma rodada
      get "/rounds/:id", FlController, :show_round

      # Status do Orchestrator
      get "/status", FlController, :orchestrator_status

      # Participante submete gradientes (usado pelos nós Flower)
      post "/rounds/:id/gradients", FlController, :submit_gradients
    end
  end
end
