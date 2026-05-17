defmodule FhirFlBridge.Repo.Schemas.FLRound do
  @moduledoc """
  Schema Ecto para rodadas de Federated Learning.

  Representa o ciclo de vida completo de uma rodada:
  pending → distributing → collecting → aggregating → completed | failed

  O campo `global_weights` (JSONB) armazena o vetor θ_global resultante
  da agregação FedAvg ponderada.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "fl_rounds" do
    field :status, :string, default: "pending"
    field :model_version, :integer
    field :aggregation_strategy, :string, default: "weighted_fedavg"
    field :total_participants, :integer
    field :completed_participants, :integer, default: 0
    field :global_weights, :map
    field :started_at,   :utc_datetime
    field :completed_at, :utc_datetime

    has_many :participants, FhirFlBridge.Repo.Schemas.FLParticipant,
      foreign_key: :fl_round_id

    timestamps()
  end

  @valid_statuses ~w(pending distributing collecting aggregating completed failed)

  @doc false
  def changeset(round, attrs) do
    round
    |> cast(attrs, [
      :id,
      :status,
      :model_version,
      :aggregation_strategy,
      :total_participants,
      :completed_participants,
      :global_weights,
      :started_at,
      :completed_at
    ])
    |> validate_required([:id, :model_version, :total_participants])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:model_version, greater_than: 0)
    |> validate_number(:total_participants, greater_than_or_equal_to: 0)
  end
end
