import Config

config :fhir_fl_bridge, FhirFlBridgeWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4001],  # 0.0.0.0 — aceita conexões externas ao container
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev_secret_key_base_mindala_fhir_fl_bridge_not_for_production_use",
  watchers: []

# Lê DATABASE_URL se definida (ex: dentro do Docker).
# Caso contrário, usa conexão local padrão para desenvolvimento nativo.
if database_url = System.get_env("DATABASE_URL") do
  config :fhir_fl_bridge, FhirFlBridge.Repo,
    url: database_url,
    stacktrace: true,
    show_sensitive_data_on_connection_error: true,
    pool_size: 10
else
  config :fhir_fl_bridge, FhirFlBridge.Repo,
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    database: "fhir_fl_bridge_dev",
    stacktrace: true,
    show_sensitive_data_on_connection_error: true,
    pool_size: 10
end

# Lê LEXICON_BASE_URL se definida (ex: dentro do Docker onde P1 é http://p1:8000).
# Em desenvolvimento local, usa localhost:8000.
if lexicon_url = System.get_env("LEXICON_BASE_URL") do
  config :fhir_fl_bridge, :lexicon_client,
    base_url: lexicon_url,
    api_key: System.get_env("LEXICON_API_KEY", "dev-key-mindala"),
    timeout: 10_000,
    retry_attempts: 3,
    retry_delay: 500
end


config :logger, :console, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
