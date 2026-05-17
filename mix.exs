defmodule FhirFlBridge.MixProject do
  use Mix.Project

  # -------------------------------------------------------------------
  # Parábola do Tecelão de Redes
  #
  # Um tecelão de redes foi perguntado: "Como você sabe que a rede está
  # pronta?" Ele respondeu: "Quando cada nó está conectado ao próximo
  # com a tensão certa — nem frouxa, nem apertada demais. Uma rede mal
  # tensionada perde o peixe. Uma rede bem tensionada alimenta a aldeia."
  #
  # Este mix.exs é a rede que conecta todos os fios do P2.
  # — Parábola dos Pescadores do Rio São Francisco
  # -------------------------------------------------------------------

  def project do
    [
      app: :fhir_fl_bridge,
      version: "0.1.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      # Metadados do projeto
      name: "FHIR-FL Bridge",
      description: "P2: Bridge FHIR e Orquestrador de Federated Learning — Mindala Health",
      source_url: "https://github.com/mindala-health/fhir-fl-bridge"
    ]
  end

  # OTP Application
  def application do
    [
      mod: {FhirFlBridge.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto]
    ]
  end

  # Caminhos de compilação por ambiente
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # --- Phoenix Framework ---
      {:phoenix, "~> 1.7"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_live_view, "~> 0.20"},   # Para o dashboard de auditoria (futuro)
      {:phoenix_live_dashboard, "~> 0.8"},

      # --- Banco de Dados ---
      {:ecto_sql, "~> 3.11"},
      {:postgrex, "~> 0.18"},

      # --- HTTP Client (comunicação com P1 — Lexicon Vivo) ---
      {:tesla, "~> 1.11"},
      {:hackney, "~> 1.20"},             # Adapter HTTP para Tesla
      {:jason, "~> 1.4"},                # JSON encode/decode

      # --- Validação FHIR ---
      {:ex_json_schema, "~> 0.10"},      # Validação de schemas FHIR R5

      # --- Observabilidade ---
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:plug_cowboy, "~> 2.7"},

      # --- Utilitários ---
      {:uuid, "~> 1.1"},
      {:timex, "~> 3.7"},                # Manipulação de datas/horários

      # --- Desenvolvimento ---
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:floki, ">= 0.30.0", only: :test},

      # --- Testes ---
      {:mox, "~> 1.1", only: :test},
      {:ex_machina, "~> 2.8", only: [:test, :dev]},
      {:excoveralls, "~> 0.18", only: :test},
      {:bypass, "~> 2.1", only: :test}   # Mock de servidor HTTP externo (P1)
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "test.coverage": ["coveralls.html"]
    ]
  end
end
