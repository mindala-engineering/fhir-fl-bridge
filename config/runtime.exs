import Config

# runtime.exs é carregado APÓS compilação — permite variáveis de ambiente em produção.

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "Variável de ambiente DATABASE_URL não definida. " <>
              "Para desenvolvimento, veja config/dev.exs."

  config :fhir_fl_bridge, FhirFlBridge.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    ssl: true

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "Variável de ambiente SECRET_KEY_BASE não definida. " <>
              "Execute: mix phx.gen.secret"

  host = System.get_env("PHX_HOST") || "mindala.health"
  port = String.to_integer(System.get_env("PORT") || "4001")

  config :fhir_fl_bridge, FhirFlBridgeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base

  # Lexicon P1 em produção
  config :fhir_fl_bridge, :lexicon_client,
    base_url:
      System.get_env("LEXICON_BASE_URL") ||
        raise("Variável LEXICON_BASE_URL não definida"),
    api_key:
      System.get_env("LEXICON_API_KEY") ||
        raise("Variável LEXICON_API_KEY não definida")

  # FL config em produção
  config :fhir_fl_bridge, :fl_config,
    round_timeout_ms: String.to_integer(System.get_env("FL_ROUND_TIMEOUT_MS") || "300000"),
    min_participants: String.to_integer(System.get_env("FL_MIN_PARTICIPANTS") || "2")
end
