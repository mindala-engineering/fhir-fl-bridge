defmodule FhirFlBridge.Repo.Schemas.FLParticipant do
  @moduledoc """
  Schema Ecto para participantes de uma rodada FL.

  Cada registro representa um nó municipal convidado para uma rodada.
  O campo `confidence_weight` é o peso epistêmico calculado via P1 —
  determina a influência dos gradientes deste município no modelo global.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  schema "fl_participants" do
    field :fl_round_id, :string
    field :municipality_code, :string
    field :node_url, :string
    field :confidence_weight, :float
    field :local_gradients, :map
    field :samples_count, :integer
    field :status, :string, default: "invited"
    field :submitted_at, :utc_datetime

    belongs_to :fl_round, FhirFlBridge.Repo.Schemas.FLRound,
      foreign_key: :fl_round_id,
      define_field: false

    timestamps()
  end

  @valid_statuses ~w(invited training submitted timeout failed)

  @doc false
  def changeset(participant, attrs) do
    participant
    |> cast(attrs, [
      :fl_round_id,
      :municipality_code,
      :node_url,
      :confidence_weight,
      :local_gradients,
      :samples_count,
      :status,
      :submitted_at
    ])
    |> validate_required([:fl_round_id, :municipality_code, :confidence_weight])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:confidence_weight, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  end
end
