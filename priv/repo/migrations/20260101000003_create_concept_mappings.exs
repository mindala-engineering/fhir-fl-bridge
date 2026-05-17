defmodule FhirFlBridge.Repo.Migrations.CreateConceptMappings do
  use Ecto.Migration

  def change do
    create table(:concept_mappings, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      # Código local do município (ex: "acupuntura-florian-001")
      add :original_code, :string, null: false
      # Sistema de origem (OID, URL, etc.)
      add :original_system, :string
      # UUID do conceito canônico no Lexicon Vivo (P1)
      add :canonical_concept_id, :string
      # Score de confiança epistêmica retornado pelo P1 (0.0–1.0)
      add :confidence_score, :float
      # Score de relevância textual Lucene retornado pelo P1
      add :lucene_score, :float
      # Status do mapeamento: auto_accepted | pending_review | rejected
      add :status, :string, null: false, default: "pending_review"
      # Guardião Epistêmico que revisou (se revisado manualmente)
      add :reviewed_by, :string
      # Município de origem (código IBGE)
      add :municipality_code, :string, null: false
      # Tipo do recurso FHIR (Observation, Condition, Procedure, etc.)
      add :fhir_resource_type, :string
      # Timestamp do mapeamento
      add :mapped_at, :utc_datetime

      timestamps()
    end

    create index(:concept_mappings, [:municipality_code])
    create index(:concept_mappings, [:status])
    create index(:concept_mappings, [:canonical_concept_id])
    create index(:concept_mappings, [:confidence_score])
    # Índice composto para queries do Orchestrator (municípios com mapeamentos aceitos)
    create index(:concept_mappings, [:municipality_code, :status])
  end
end
