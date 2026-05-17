# P2 — FHIR-FL Bridge
### Mindala Health — CNPJ 64.763.242/0001-10

> *"Antes de construir uma ponte, é preciso conhecer os dois rios que ela vai unir.*
> *Não basta medir a distância — é preciso entender a correnteza de cada um."*
> — Parábola do Engenheiro de Pontes (tradição oral do sertão nordestino)

---

## O que é este serviço?

O **FHIR-FL Bridge** é o Pilar 2 da plataforma Mindala Health. Ele resolve dois problemas centrais
da infraestrutura de MTCI no SUS:

1. **Tradução terminológica**: converte códigos FHIR locais de municípios para os conceitos
   canônicos do **Lexicon Vivo (P1)**, aplicando regras de threshold epistêmico.

2. **Orquestração de Federated Learning**: coordena rodadas de treinamento distribuído com nós
   municipais (Python/Flower) usando Elixir/OTP como motor de supervisão, ponderando gradientes
   pelo `confidenceScore` do Lexicon Vivo.

**Stack:** Elixir/OTP · Phoenix · Ecto · PostgreSQL · Tesla

---

## Pré-requisitos

| Ferramenta | Versão mínima |
|---|---|
| Elixir | 1.16+ |
| Erlang/OTP | 26+ |
| PostgreSQL | 15+ |
| P1 Lexicon Vivo | rodando em `http://localhost:8000` |

### Instalar Elixir (via asdf — recomendado)

```bash
asdf plugin add erlang
asdf plugin add elixir

asdf install erlang 26.2.5
asdf install elixir 1.16.3-otp-26

# No diretório do projeto:
asdf local erlang 26.2.5
asdf local elixir 1.16.3-otp-26
```

---

## Setup

### 1. Instalar dependências

```bash
cd FHIR-FL-Bridge
mix deps.get
```

### 2. Configurar variáveis de ambiente

Copie o arquivo de exemplo e edite:

```bash
cp .env.example .env
```

Conteúdo de `.env`:

```env
# Banco de dados
DATABASE_URL=ecto://postgres:postgres@localhost/fhir_fl_bridge_dev

# P1 — Lexicon Vivo
LEXICON_BASE_URL=http://localhost:8000
LEXICON_API_KEY=dev-key-mindala

# Servidor Phoenix
PHX_HOST=localhost
PORT=4001
SECRET_KEY_BASE=gere_com_mix_phx.gen.secret
```

Gerar `SECRET_KEY_BASE`:

```bash
mix phx.gen.secret
```

### 3. Criar e migrar banco de dados

```bash
mix ecto.create
mix ecto.migrate
```

### 4. (Opcional) Popular banco com dados de exemplo

```bash
mix run priv/repo/seeds.exs
```

---

## Execução

### Desenvolvimento

```bash
mix phx.server
# Ou com IEx interativo (recomendado para debug):
iex -S mix phx.server
```

O serviço estará disponível em `http://localhost:4001`.

### Verificar se está saudável

```bash
curl http://localhost:4001/health
# → {"status":"ok","service":"fhir-fl-bridge","version":"0.1.0"}
```

---

## API — Endpoints principais

### Bridge FHIR

#### Mapear um recurso FHIR

```bash
POST /api/v1/fhir/map
Content-Type: application/json
{ 
{
  "resourceType": "Observation",
  "code": {
    "coding": [
      {
        "system": "urn:oid:2.16.840.1.113883.13.236",
        "code": "acupuntura-local-001"
      }
    ],
    "text": "Acupuntura para dor lombar crônica"
  },
  "municipality_code": "4205407"
}
```

**Resposta:**

```json
{
  "status": "auto_accepted",
  "confidence_score": 0.91,
  "lucene_score": 0.87,
  "canonical_concept_id": "uuid-do-conceito",
  "fhir_coding": {
    "system": "https://mindala.health/fhir/CodeSystem/lexicon-vivo",
    "code": "TCM-ACUP-001",
    "display": "Acupuntura"
  }
}
```

#### Listar mapeamentos pendentes (fila do Guardião)

```bash
GET /api/v1/fhir/mappings?status=pending_review
```

#### Revisar mapeamento (Guardião Epistêmico)

```bash
PATCH /api/v1/fhir/mappings/:id/review
Content-Type: application/json

{
  "decision": "approve",
  "reviewed_by": "guardiao-001",
  "canonical_concept_id": "uuid-confirmado"
}
```

### Federated Learning

#### Iniciar rodada FL manualmente

```bash
POST /api/v1/fl/rounds
Content-Type: application/json

{
  "model_version": 3,
  "participants": [
    { "municipality_code": "4205407", "node_url": "http://florianopolis-node:8080" },
    { "municipality_code": "4202404", "node_url": "http://blumenau-node:8080" }
  ]
}
```

#### Status de uma rodada

```bash
GET /api/v1/fl/rounds/:id
```

#### Listar todas as rodadas

```bash
GET /api/v1/fl/rounds
```

---

## Testes

### Rodar suite completa

```bash
mix test
```

### Com cobertura

```bash
mix test --cover
```

### Apenas um módulo

```bash
mix test test/fhir_fl_bridge/fhir/mapper_test.exs
```

### Modo verbose (útil para debug)

```bash
mix test --trace
```

### Testes de integração (requerem P1 rodando)

```bash
MIX_ENV=integration mix test --include integration
```

---

## Estrutura do projeto

```
FHIR-FL-Bridge/
├── PLANNING.md                         # Especificação técnica completa
├── README.md                           # Este arquivo
├── mix.exs                             # Dependências e configuração do projeto
├── config/
│   ├── config.exs                      # Configuração base
│   ├── dev.exs                         # Desenvolvimento
│   ├── test.exs                        # Testes (usa mocks do P1)
│   └── runtime.exs                     # Variáveis de ambiente em produção
├── lib/
│   ├── fhir_fl_bridge/
│   │   ├── application.ex              # Supervision tree OTP
│   │   ├── lexicon/
│   │   │   └── client.ex               # Tesla HTTP client para P1
│   │   ├── fhir/
│   │   │   ├── bridge.ex               # GenServer: state machine de mapeamentos
│   │   │   ├── mapper.ex               # Lógica de transformação FHIR ↔ Lexicon
│   │   │   └── validator.ex            # Regras de threshold epistêmico
│   │   ├── fl/
│   │   │   ├── orchestrator.ex         # GenServer: coordenador de rodadas FL
│   │   │   ├── round_supervisor.ex     # DynamicSupervisor para rodadas
│   │   │   ├── round_worker.ex         # GenServer: lifecycle de uma rodada
│   │   │   └── aggregator.ex           # FedAvg ponderado por confidenceScore
│   │   └── repo/
│   │       ├── repo.ex                 # Ecto Repo
│   │       └── schemas/
│   │           ├── fl_round.ex         # Schema: rodada FL
│   │           ├── fl_participant.ex   # Schema: participante da rodada
│   │           └── concept_mapping.ex  # Schema: mapeamento de conceito
│   └── fhir_fl_bridge_web/
│       ├── endpoint.ex                 # Phoenix Endpoint
│       ├── router.ex                   # Rotas HTTP
│       └── controllers/
│           ├── fhir_controller.ex      # Controller: Bridge FHIR
│           └── fl_controller.ex        # Controller: Orquestrador FL
├── priv/
│   └── repo/
│       └── migrations/
│           ├── 001_create_fl_rounds.exs
│           ├── 002_create_fl_participants.exs
│           └── 003_create_concept_mappings.exs
└── test/
    ├── test_helper.exs
    ├── fhir_fl_bridge/
    │   ├── lexicon/client_test.exs
    │   ├── fhir/bridge_test.exs
    │   ├── fhir/mapper_test.exs
    │   └── fl/aggregator_test.exs
    └── support/
        └── factory.ex
```

---

## Conceitos importantes

### Regras de threshold epistêmico

O `confidenceScore` retornado pelo P1 determina o destino de cada mapeamento:

| Score | Status | Ação |
|---|---|---|
| `>= 0.85` | `auto_accepted` | Mapeamento aceito automaticamente |
| `0.50 – 0.84` | `pending_review` | Enviado para fila do Guardião Epistêmico |
| `< 0.50` | `rejected` | Bloqueado até revisão humana |

### Guardião Epistêmico

Papel (role) responsável por revisar mapeamentos `pending_review`. Definido no P3 (Consent Engine)
e referenciado aqui pelo campo `reviewed_by` em `concept_mappings`.

### FedAvg Ponderado

Na agregação federada, o peso de cada nó municipal é seu `confidence_weight`, derivado do score
médio dos conceitos mapeados para aquele município. Nós que usam terminologia confiável têm maior
influência no modelo global.

---

## Variáveis de ambiente (referência completa)

| Variável | Obrigatória | Padrão | Descrição |
|---|---|---|---|
| `DATABASE_URL` | ✅ | — | URL de conexão PostgreSQL |
| `LEXICON_BASE_URL` | ✅ | — | URL base do P1 |
| `LEXICON_API_KEY` | ✅ | — | Chave de autenticação do P1 |
| `PHX_HOST` | ✅ (prod) | `localhost` | Host do servidor Phoenix |
| `PORT` | ❌ | `4001` | Porta HTTP |
| `SECRET_KEY_BASE` | ✅ | — | Chave secreta Phoenix |
| `FL_ROUND_TIMEOUT_MS` | ❌ | `300000` | Timeout por rodada FL (5 min) |
| `FL_MIN_PARTICIPANTS` | ❌ | `2` | Mínimo de participantes para agregar |
| `POOL_SIZE` | ❌ | `10` | Tamanho do pool de conexões BD |

---

## Troubleshooting

### `** (Mix) The database for FhirFlBridge.Repo couldn't be created`

Verifique se o PostgreSQL está rodando e se `DATABASE_URL` está configurada corretamente.

### `Tesla.Error` nos testes do `LexiconClient`

Os testes usam Mox para mockar o P1. Se estiver rodando testes de integração, verifique se
o P1 está em `http://localhost:8000`.

### `GenServer FhirFlBridge.FL.Orchestrator not found`

O Orchestrator não subiu. Verifique os logs com `mix phx.server` — pode ser problema de
conexão com PostgreSQL na inicialização.

---

## Contribuição

Este é um serviço interno da Mindala Health. Para contribuições:

1. Leia o `PLANNING.md` para entender as decisões de arquitetura
2. Todo novo módulo deve incluir uma parábola no cabeçalho (tradição iniciada no P1)
3. Testes são obrigatórios para qualquer lógica de negócio
4. Siga o guia de estilo Elixir: `mix format` antes de commitar

---

*Mindala Health — infraestrutura digital para a medicina tradicional e integrativa*
*Florianópolis, SC · 2026*
