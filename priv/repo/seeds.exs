# Script de seeds — popula o banco com dados de exemplo para desenvolvimento
#
# Uso: mix run priv/repo/seeds.exs
# (Executado automaticamente por `mix ecto.setup`)

alias FhirFlBridge.Repo
alias FhirFlBridge.Repo.Schemas.{FLRound, ConceptMapping}

IO.puts("Populando banco com dados de exemplo...")

# -------------------------------------------------------------------
# Mapeamentos de conceito de exemplo
# -------------------------------------------------------------------

concepts_seed = [
  %{
    original_code: "acupuntura-florian-001",
    original_system: "urn:oid:2.16.840.1.113883.13.236",
    canonical_concept_id: "uuid-tcm-acupuntura-001",
    confidence_score: 0.91,
    lucene_score: 0.87,
    status: "auto_accepted",
    municipality_code: "4205407",
    fhir_resource_type: "Observation",
    mapped_at: DateTime.utc_now() |> DateTime.truncate(:second)
  },
  %{
    original_code: "plantas-medicinais-blum-003",
    original_system: "urn:oid:2.16.840.1.113883.13.236",
    canonical_concept_id: "uuid-mtb-plantas-003",
    confidence_score: 0.72,
    lucene_score: 0.65,
    status: "pending_review",
    municipality_code: "4202404",
    fhir_resource_type: "Observation",
    mapped_at: DateTime.utc_now() |> DateTime.truncate(:second)
  },
  %{
    original_code: "homeopatia-joinv-007",
    original_system: "urn:oid:2.16.840.1.113883.13.236",
    canonical_concept_id: nil,
    confidence_score: 0.30,
    lucene_score: 0.40,
    status: "rejected",
    municipality_code: "4209102",
    fhir_resource_type: "Procedure",
    mapped_at: DateTime.utc_now() |> DateTime.truncate(:second)
  }
]

Enum.each(concepts_seed, fn attrs ->
  %ConceptMapping{}
  |> ConceptMapping.changeset(attrs)
  |> Repo.insert!(on_conflict: :nothing)
end)

IO.puts("✓ #{length(concepts_seed)} mapeamentos de conceito inseridos")

# -------------------------------------------------------------------
# Rodada FL de exemplo (concluída)
# -------------------------------------------------------------------

round_id = "seed-round-001"

%FLRound{}
|> FLRound.changeset(%{
  id: round_id,
  status: "completed",
  model_version: 1,
  total_participants: 2,
  completed_participants: 2,
  aggregation_strategy: "weighted_fedavg",
  global_weights: %{
    "layer_1" => [0.15, 0.22, 0.31],
    "layer_2" => [0.44, 0.55],
    "output" => [0.67]
  },
  started_at: DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second),
  completed_at: DateTime.utc_now() |> DateTime.add(-3000, :second) |> DateTime.truncate(:second)
})
|> Repo.insert!(on_conflict: :nothing)

IO.puts("✓ Rodada FL de exemplo inserida (id: #{round_id})")
IO.puts("\nSeeds concluídos. Acesse http://localhost:4001/api/v1/fhir/mappings para verificar.")
