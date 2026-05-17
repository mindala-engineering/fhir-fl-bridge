defmodule FhirFlBridge.Repo.Migrations.CreateFlParticipants do
  use Ecto.Migration

  def change do
    create table(:fl_participants, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :fl_round_id, references(:fl_rounds, type: :string, on_delete: :delete_all), null: false
      add :municipality_code, :string, null: false
      add :node_url, :string
      # Peso epistêmico derivado do Lexicon Vivo — determina influência no modelo global
      add :confidence_weight, :float, null: false, default: 0.5
      # Gradientes locais retornados pelo nó Flower (jsonb)
      add :local_gradients, :map
      add :samples_count, :integer
      add :status, :string, null: false, default: "invited"
      add :submitted_at, :utc_datetime

      timestamps()
    end

    create index(:fl_participants, [:fl_round_id])
    create index(:fl_participants, [:municipality_code])
    create index(:fl_participants, [:status])
    create unique_index(:fl_participants, [:fl_round_id, :municipality_code])
  end
end
