defmodule FhirFlBridge.Repo.Migrations.CreateFlRounds do
  use Ecto.Migration

  def change do
    # ENUM para status da rodada FL
    execute(
      "CREATE TYPE fl_round_status AS ENUM ('pending', 'distributing', 'collecting', 'aggregating', 'completed', 'failed')",
      "DROP TYPE fl_round_status"
    )

    create table(:fl_rounds, primary_key: false) do
      add :id, :string, primary_key: true
      add :status, :string, null: false, default: "pending"
      add :model_version, :integer, null: false
      add :aggregation_strategy, :string, null: false, default: "weighted_fedavg"
      add :total_participants, :integer, null: false, default: 0
      add :completed_participants, :integer, null: false, default: 0
      # θ_global — vetor de pesos agregados (jsonb para flexibilidade)
      add :global_weights, :map
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps()
    end

    create index(:fl_rounds, [:status])
    create index(:fl_rounds, [:model_version])
    create index(:fl_rounds, [:started_at])
  end
end
