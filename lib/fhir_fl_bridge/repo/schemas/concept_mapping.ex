defmodule FhirFlBridge.Repo.Schemas.ConceptMapping do
  @moduledoc """
  Schema Ecto para mapeamentos terminológicos FHIR ↔ Lexicon Vivo.

  Cada registro documenta a resolução de um código FHIR local de um
  município para um conceito canônico do Lexicon Vivo (P1).

  O campo `status` implementa as regras de threshold epistêmico:
  - `auto_accepted` (score >= 0.85): mapeamento imediato
  - `pending_review` (0.50 <= score < 0.85): fila do Guardião Epistêmico
  - `rejected` (score < 0.50): bloqueado até revisão humana

  O campo `reviewed_by` é preenchido quando o Guardião Epistêmico
  (role definido no P3) revisa manualmente um mapeamento.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "concept_mappings" do
    field :original_code, :string
    field :original_system, :string
    field :canonical_concept_id, :string
    field :confidence_score, :float
    field :lucene_score, :float
    field :status, :string, default: "pending_review"
    field :reviewed_by, :string
    field :municipality_code, :string
    field :fhir_resource_type, :string
    field :mapped_at, :utc_datetime

    timestamps()
  end

  @valid_statuses ~w(auto_accepted pending_review rejected)

  @doc false
  def changeset(mapping, attrs) do
    mapping
    |> cast(attrs, [
      :original_code,
      :original_system,
      :canonical_concept_id,
      :confidence_score,
      :lucene_score,
      :status,
      :reviewed_by,
      :municipality_code,
      :fhir_resource_type,
      :mapped_at
    ])
    |> validate_required([:original_code, :municipality_code, :status])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:confidence_score,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
  end
end
