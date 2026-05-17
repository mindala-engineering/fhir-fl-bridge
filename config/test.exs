import Config

# Em testes, o cliente Lexicon é mockado via Mox.
config :fhir_fl_bridge, :lexicon_client_module, FhirFlBridge.Lexicon.ClientMock

# Lê DATABASE_URL se definida (Docker). Caso contrário, usa localhost.
# Mantém pool: Ecto.Adapters.SQL.Sandbox em ambos os casos — obrigatório para testes.
if database_url = System.get_env("DATABASE_URL") do
  # Troca o nome do banco para o banco de teste (não polui o banco de dev)
  test_url = Regex.replace(~r{/[^/]+$}, database_url, "/fhir_fl_bridge_test")

  config :fhir_fl_bridge, FhirFlBridge.Repo,
    url: test_url,
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 10
else
  config :fhir_fl_bridge, FhirFlBridge.Repo,
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    database: "fhir_fl_bridge_test#{System.get_env("MIX_TEST_PARTITION")}",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: System.schedulers_online() * 2
end

config :fhir_fl_bridge, FhirFlBridgeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_mindala_fhir_fl_bridge_for_test_only",
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime
