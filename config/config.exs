import Config

# Configuração base — compartilhada por todos os ambientes.
# Sobrescrita por dev.exs, test.exs e runtime.exs.

config :fhir_fl_bridge, FhirFlBridgeWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [json: FhirFlBridgeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: FhirFlBridge.PubSub,
  live_view: [signing_salt: "mindala_lv_salt"]

# Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :round_id, :municipality_code]

# Phoenix
config :phoenix, :json_library, Jason

# Ecto
config :fhir_fl_bridge, ecto_repos: [FhirFlBridge.Repo]

# -------------------------------------------------------------------
# Configurações do P2 — FHIR-FL Bridge
# -------------------------------------------------------------------

# Configuração do cliente Lexicon (P1)
config :fhir_fl_bridge, :lexicon_client,
  # Em produção, sobrescrito por runtime.exs via LEXICON_BASE_URL
  base_url: "http://localhost:8000",
  api_key: "dev-key-mindala",
  timeout: 10_000,
  # Retry automático em falhas transitórias
  retry_attempts: 3,
  retry_delay: 500

# Regras de threshold epistêmico (imutáveis por design — alterar requer decisão do Guardião)
config :fhir_fl_bridge, :epistemic_thresholds,
  auto_accept: 0.85,
  review_floor: 0.50

# Configurações de Federated Learning
config :fhir_fl_bridge, :fl_config,
  round_timeout_ms: 300_000,     # 5 minutos por rodada
  min_participants: 2,           # Mínimo para agregar
  aggregation_strategy: :weighted_fedavg

# Importar configurações de ambiente específico
import_config "#{config_env()}.exs"
