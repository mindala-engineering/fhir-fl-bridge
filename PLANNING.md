# PLANNING.md — P2: FHIR-FL Bridge
## Mindala Health — CNPJ 64.763.242/0001-10

> *"O rio não luta contra as pedras — ele as abraça, contorna e segue seu caminho.*
> *Da mesma forma, a ponte não nega as diferenças entre as margens: ela as honra e as une."*
> — Parábola do Rio e da Ponte (tradição oral caiçara)

---

## 1. Visão e Propósito

O **P2 — FHIR-FL Bridge** é o coração operacional da plataforma Mindala. Ele resolve dois
problemas fundamentais da interoperabilidade em saúde pública:

1. **Heterogeneidade terminológica**: municípios do SUS usam códigos locais, nomes populares e
   sistemas próprios. O P2 traduz esses fragmentos para o vocabulário epistêmico do Lexicon Vivo (P1).

2. **Aprendizado distribuído sem centralização de dados**: o P2 orquestra rodadas de
   Federated Learning com nós municipais (Python/Flower) usando OTP/GenServer como motor de
   supervisão fault-tolerant, e pondera os gradientes com o `confidenceScore` epistêmico do P1.

---

## 2. Responsabilidades Formais

### 2.1 Bridge FHIR (Responsabilidade 1)

Receber recursos FHIR R4/R5 (CodeSystem, ValueSet, Observation, Condition) de municípios e
mapear seus códigos locais para conceitos canônicos do Lexicon Vivo via P1.

**Contrato de entrada:**
```json
{
  "resourceType": "Observation",
  "code": {
    "coding": [{ "system": "urn:oid:2.16.840.1.113883.13.236", "code": "acupuntura-florian-001" }],
    "text": "Acupuntura sistêmica para dor lombar"
  }
}
```

**Contrato de saída (mapeamento resolvido):**
```json
{
  "original_code": "acupuntura-florian-001",
  "canonical_concept_id": "uuid-do-conceito-p1",
  "confidence_score": 0.91,
  "lucene_score": 0.87,
  "status": "auto_accepted",
  "fhir_coding": {
    "system": "https://mindala.health/fhir/CodeSystem/lexicon-vivo",
    "code": "TCM-ACUP-001",
    "display": "Acupuntura"
  }
}
```

### 2.2 Orquestrador FL (Responsabilidade 2)

Coordenar rodadas de treinamento federado com nós municipais. Cada rodada é um processo OTP
supervisionado com lifecycle gerenciado por GenServer.

**Estados de uma rodada FL:**
```
:pending → :distributing → :collecting → :aggregating → :completed | :failed
```

### 2.3 Agregação Ponderada (Responsabilidade 3)

Implementar FedAvg com pesos derivados do `confidenceScore` do Lexicon Vivo.

**Fórmula:**
```
w_i = confidence_score(conceito_i)  ∈ [0.0, 1.0]
θ_global = Σ(w_i * θ_i) / Σ(w_i)
```

Intuição: um nó municipal que usa terminologia altamente confiante (validada pelo Guardião
Epistêmico) tem maior peso na atualização do modelo global.

---

## 3. Contrato Formal com P1 (Lexicon Vivo)

| Endpoint P1 | Uso no P2 | Campo crítico |
|---|---|---|
| `GET /v1/search/?q={termo}&min_confidence=0.5` | Resolver código FHIR local | `confidenceScore`, `luceneScore` |
| `GET /v1/concepts/{id}?include_relations=true` | Enriquecer mapeamento com vizinhos SKOS | `relations[]` |
| `GET /v1/fhir/CodeSystem` | Sincronizar vocabulário canônico | `concept[].code` |

### 3.1 Regras de Threshold (implementadas em `FhirFlBridge.FHIR.Validator`)

```
confidenceScore >= 0.85  → :auto_accepted   (mapeamento automático)
0.50 <= score < 0.85     → :pending_review  (fila do Guardião Epistêmico)
score < 0.50             → :rejected        (bloqueado até revisão humana)
```

---

## 4. Arquitetura OTP

```
FhirFlBridge.Application (Supervisor, strategy: :one_for_one)
├── FhirFlBridge.Repo                          # Ecto + PostgreSQL
├── FhirFlBridgeWeb.Endpoint                   # Phoenix HTTP
├── FhirFlBridge.Lexicon.Client                # Tesla HTTP pool para P1
├── FhirFlBridge.FHIR.Bridge                   # GenServer: bridge state machine
└── FhirFlBridge.FL.Orchestrator               # GenServer: coordenador de rodadas
    └── FhirFlBridge.FL.RoundSupervisor         # DynamicSupervisor
        └── [FhirFlBridge.FL.RoundWorker]       # GenServer por rodada ativa
```

**Justificativa OTP:**
- `one_for_one`: falha em um componente não derruba os outros (Bridge pode falhar sem
  interromper FL em andamento)
- `DynamicSupervisor` para rodadas: número variável de municípios; cada rodada é isolada
- Restart `:permanent` para Bridge e Orchestrator; `:temporary` para RoundWorkers

---

## 5. Modelagem de Dados (PostgreSQL + Ecto)

### 5.1 `fl_rounds`
| Campo | Tipo | Descrição |
|---|---|---|
| `id` | UUID | Identificador da rodada |
| `status` | ENUM | `pending \| distributing \| collecting \| aggregating \| completed \| failed` |
| `model_version` | integer | Versão do modelo global |
| `aggregation_strategy` | string | `"weighted_fedavg"` (default) |
| `total_participants` | integer | Nós convocados |
| `completed_participants` | integer | Nós que retornaram gradientes |
| `global_weights` | jsonb | Vetor de pesos agregados (θ_global) |
| `started_at` | utc_datetime | Início da rodada |
| `completed_at` | utc_datetime | Fim da rodada |

### 5.2 `fl_participants`
| Campo | Tipo | Descrição |
|---|---|---|
| `id` | UUID | |
| `fl_round_id` | UUID (FK) | Rodada associada |
| `municipality_code` | string | Código IBGE do município |
| `node_url` | string | Endpoint Flower do nó |
| `confidence_weight` | float | Peso epistêmico derivado do P1 |
| `local_gradients` | jsonb | Gradientes retornados pelo nó |
| `samples_count` | integer | Volume de dados locais |
| `status` | ENUM | `invited \| training \| submitted \| timeout \| failed` |
| `submitted_at` | utc_datetime | |

### 5.3 `concept_mappings`
| Campo | Tipo | Descrição |
|---|---|---|
| `id` | UUID | |
| `original_code` | string | Código local do município |
| `original_system` | string | Sistema de origem (OID, URL) |
| `canonical_concept_id` | string | ID do conceito no P1 |
| `confidence_score` | float | Score retornado pelo P1 |
| `lucene_score` | float | Score textual retornado pelo P1 |
| `status` | ENUM | `auto_accepted \| pending_review \| rejected` |
| `reviewed_by` | string | ID do Guardião Epistêmico (se revisado) |
| `municipality_code` | string | Município de origem |
| `fhir_resource_type` | string | `Observation`, `Condition`, etc. |
| `mapped_at` | utc_datetime | |

---

## 6. Stack e Dependências

```elixir
# mix.exs
{:phoenix, "~> 1.7"},
{:phoenix_ecto, "~> 4.5"},
{:ecto_sql, "~> 3.11"},
{:postgrex, "~> 0.18"},
{:tesla, "~> 1.11"},
{:hackney, "~> 1.20"},     # adapter HTTP para Tesla
{:jason, "~> 1.4"},
{:finch, "~> 0.18"},       # alternativa a hackney (pool de conexões)
{:ex_json_schema, "~> 0.10"}, # validação de esquemas FHIR
{:telemetry_metrics, "~> 1.0"},
{:telemetry_poller, "~> 1.1"},

# Test
{:mox, "~> 1.1", only: :test},
{:ex_machina, "~> 2.8", only: :test},
```

---

## 7. Decisões de Design

### 7.1 Por que Elixir/OTP para o orquestrador FL?

O problema do FL é fundamentalmente um problema de **coordenação de processos concorrentes com
falhas parciais**. OTP resolve isso nativamente:

- Timeout por nó municipal → `Process.send_after/3` + `handle_info(:timeout)`
- Nó que cai → `RoundWorker` recebe `DOWN` e atualiza estado da rodada
- Retomada de rodada após crash do orquestrador → estado persistido no PostgreSQL

Python/asyncio ou Node.js resolveriam isso com workarounds. OTP é a solução natural.

### 7.2 Por que Tesla para o cliente P1?

Tesla é middleware-composable: adiciona retry automático, circuit breaker, logging, e mock para
testes sem mudar o código de produção. Fundamental para a resiliência de P2 frente a
indisponibilidade eventual de P1.

### 7.3 Separação Bridge vs Orchestrator

São dois GenServers independentes por design. O Bridge pode ficar offline (P1 indisponível) sem
interromper rodadas FL já em andamento. O Orchestrator pode estar agregando enquanto o Bridge
processa novas admissões. `one_for_one` garante essa independência.

---

## 8. Fluxo de Dados Completo

```
Município envia FHIR Resource
         ↓
FhirController.create/2 (Phoenix)
         ↓
FHIR.Bridge.map_resource/1 (GenServer cast)
         ↓
Lexicon.Client.search/2 (Tesla → P1)
         ↓
FHIR.Validator.apply_threshold/1
         ↓ (status: :auto_accepted | :pending_review | :rejected)
Repo.insert!(ConceptMapping)
         ↓ (se auto_accepted)
FL.Orchestrator.notify_new_mapping/1 (GenServer cast)
         ↓ (quando threshold de mappings atingido)
FL.Orchestrator.start_round/1
         ↓
FL.RoundSupervisor.start_child(RoundWorker)
         ↓
RoundWorker distribui modelo para nós Flower
         ↓
RoundWorker coleta gradientes
         ↓
FL.Aggregator.weighted_fedavg/1 (com confidence weights)
         ↓
Repo.update!(FLRound, global_weights: θ_global)
```

---

## 9. Roadmap de Implementação

| Fase | Entrega | Status |
|---|---|---|
| 0 | Estrutura do projeto, mix.exs, config | ✅ |
| 1 | Lexicon.Client (Tesla + mock) | ✅ |
| 2 | FHIR.Bridge + Validator + Mapper | ✅ |
| 3 | Schemas Ecto + Migrations | ✅ |
| 4 | FL.Orchestrator + RoundWorker + Supervisor | ✅ |
| 5 | FL.Aggregator (weighted FedAvg) | ✅ |
| 6 | Phoenix controllers (REST API) | ✅ |
| 7 | Suite de testes com Mox | ✅ |
| 8 | Integração real com Python/Flower | 🔜 Deploy |

---

*Documento mantido por: César Augusto Borges — Mindala Health*
*Última revisão: 2026*
