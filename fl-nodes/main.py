# =============================================================================
# fl-nodes/main.py — Nó Municipal de Federated Learning (Mock)
# Mindala Health — CNPJ 64.763.242/0001-10
#
# PARÁBOLA DO CURANDEIRO QUE NÃO SAIA DA ALDEIA
#
# O curandeiro sabia de tudo que acontecia em sua aldeia.
# Sabia quem tinha dor, quem melhorou, quem recaiu.
# Mas jamais levava esses nomes para fora — apenas o padrão.
# "Em nossa aldeia, o chá de capim-limão funciona em 8 de 10 casos."
# Isso ele compartilhava. O resto ficava entre ele e sua gente.
#
# Este serviço é aquele curandeiro. Os dados ficam aqui.
# Só os padrões — os gradientes — viajam até o centro.
#
# — Parábola do Curandeiro (tradição oral dos povos Pataxó)
# =============================================================================

"""
Nó municipal de Federated Learning para demonstração do P2.

Simula um município com dados locais de consultas MTCI.
Quando acionado pelo P2, "treina" localmente e devolve gradientes.
Os dados NUNCA saem — apenas as médias ponderadas (gradientes).

Configuração via variáveis de ambiente:
  MUNICIPALITY_CODE   — código IBGE (ex: 4205407)
  MUNICIPALITY_NAME   — nome para logs (ex: Florianópolis)
  P2_URL              — URL base do P2 (ex: http://p2:4001)
  PORT                — porta do serviço (default: 8080)
"""

import os
import sqlite3
import asyncio
import httpx
import logging
from contextlib import asynccontextmanager
from fastapi import FastAPI, BackgroundTasks
from pydantic import BaseModel
from typing import Optional

logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Configuração do município via env
# ---------------------------------------------------------------------------

MUNICIPALITY_CODE = os.getenv("MUNICIPALITY_CODE", "0000000")
MUNICIPALITY_NAME = os.getenv("MUNICIPALITY_NAME", "Município Exemplo")
P2_URL            = os.getenv("P2_URL", "http://localhost:4001")
PORT              = int(os.getenv("PORT", "8080"))

# ---------------------------------------------------------------------------
# Dados locais por município (simulam prontuários MTCI locais)
#
# Estrutura: lista de consultas com tratamento e efetividade reportada
# (0.0 = sem melhora, 1.0 = cura completa — escala Likert normalizada)
#
# Cada município tem um perfil diferente de práticas MTCI.
# O FedAvg vai revelar essa diferença e produzir um modelo global.
# ---------------------------------------------------------------------------

SEED_DATA = {
    # Florianópolis — perfil urbano, forte TCM, população universitária
    "4205407": [
        # Acupuntura — muito presente, alta efetividade
        *[{"tratamento": "acupuntura",   "efetividade": e, "sessoes": s}
          for e, s in [(0.90, 8), (0.85, 6), (0.92, 10), (0.88, 7),
                       (0.78, 5), (0.95, 12), (0.82, 6), (0.91, 9),
                       (0.87, 8), (0.93, 11)]],
        # Meditação / Yoga — forte presença
        *[{"tratamento": "meditacao",    "efetividade": e, "sessoes": s}
          for e, s in [(0.80, 16), (0.75, 12), (0.83, 20), (0.70, 8),
                       (0.78, 14), (0.85, 24), (0.72, 10)]],
        # Fitoterapia — moderada
        *[{"tratamento": "fitoterapia",  "efetividade": e, "sessoes": s}
          for e, s in [(0.72, 4), (0.68, 3), (0.75, 5), (0.70, 4)]],
        # Homeopatia — pequena presença
        *[{"tratamento": "homeopatia",   "efetividade": e, "sessoes": s}
          for e, s in [(0.60, 6), (0.55, 5), (0.65, 8)]],
    ],

    # Blumenau — perfil de imigração alemã, forte fitoterapia e homeopatia
    "4202404": [
        # Fitoterapia — dominante, tradição de ervas europeias
        *[{"tratamento": "fitoterapia",  "efetividade": e, "sessoes": s}
          for e, s in [(0.88, 6), (0.92, 8), (0.85, 5), (0.90, 7),
                       (0.87, 6), (0.93, 9), (0.89, 7), (0.91, 8),
                       (0.86, 6), (0.94, 10), (0.88, 7), (0.90, 8)]],
        # Homeopatia — forte presença (influência europeia)
        *[{"tratamento": "homeopatia",   "efetividade": e, "sessoes": s}
          for e, s in [(0.78, 8), (0.82, 10), (0.75, 7), (0.80, 9),
                       (0.76, 8), (0.83, 11), (0.79, 9)]],
        # Acupuntura — menor presença que Floripa
        *[{"tratamento": "acupuntura",   "efetividade": e, "sessoes": s}
          for e, s in [(0.70, 5), (0.68, 4), (0.73, 6), (0.71, 5)]],
        # Meditação — pequena
        *[{"tratamento": "meditacao",    "efetividade": e, "sessoes": s}
          for e, s in [(0.65, 10), (0.60, 8), (0.68, 12)]],
    ],
}

# Fallback genérico para qualquer outro município
DEFAULT_DATA = [
    *[{"tratamento": "fitoterapia",  "efetividade": 0.75, "sessoes": 5} for _ in range(10)],
    *[{"tratamento": "acupuntura",   "efetividade": 0.70, "sessoes": 6} for _ in range(8)],
    *[{"tratamento": "homeopatia",   "efetividade": 0.65, "sessoes": 7} for _ in range(6)],
    *[{"tratamento": "meditacao",    "efetividade": 0.68, "sessoes": 12} for _ in range(5)],
]

# Ordem canônica das categorias (define a estrutura do vetor de gradientes)
TREATMENT_CATEGORIES = ["acupuntura", "fitoterapia", "homeopatia", "meditacao"]

# ---------------------------------------------------------------------------
# Banco SQLite em memória — carregado no startup
# ---------------------------------------------------------------------------

db: sqlite3.Connection = None


def init_db() -> sqlite3.Connection:
    """Cria banco SQLite em memória com consultas locais do município."""
    conn = sqlite3.connect(":memory:", check_same_thread=False)
    conn.execute("""
        CREATE TABLE consultas (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            tratamento  TEXT NOT NULL,
            efetividade REAL NOT NULL,
            sessoes     INTEGER NOT NULL DEFAULT 1
        )
    """)
    local_data = SEED_DATA.get(MUNICIPALITY_CODE, DEFAULT_DATA)
    conn.executemany(
        "INSERT INTO consultas (tratamento, efetividade, sessoes) VALUES (?, ?, ?)",
        [(r["tratamento"], r["efetividade"], r["sessoes"]) for r in local_data],
    )
    conn.commit()
    total = conn.execute("SELECT COUNT(*) FROM consultas").fetchone()[0]
    log.info(f"[{MUNICIPALITY_NAME}] SQLite inicializado com {total} consultas locais.")
    return conn


# ---------------------------------------------------------------------------
# Lógica de "treinamento" local
#
# Não é um modelo ML real — é uma prova de conceito do protocolo FL.
# Cada nó computa a efetividade média local por categoria de tratamento.
# Esses valores são os "gradientes" que o FedAvg vai agregar.
# ---------------------------------------------------------------------------

def compute_local_gradients(current_model: dict) -> dict:
    """
    Calcula gradientes locais a partir dos dados SQLite do município.

    Retorna um vetor de efetividade média por categoria, que representa
    o "conhecimento local" deste nó sobre cada prática MTCI.

    O FedAvg no P2 vai ponderar esses vetores pelo confidence_weight
    de cada município (derivado do Lexicon Vivo / P1).
    """
    gradients = {}

    for category in TREATMENT_CATEGORIES:
        row = db.execute(
            "SELECT AVG(efetividade), COUNT(*) FROM consultas WHERE tratamento = ?",
            (category,)
        ).fetchone()

        avg_effectiveness = row[0] if row[0] is not None else 0.0
        sample_count      = row[1]

        gradients[category] = {
            "local_mean":    round(avg_effectiveness, 4),
            "sample_count":  sample_count,
            # Delta em relação ao modelo atual (é aqui que FL fica interessante)
            "delta": round(
                avg_effectiveness - current_model.get(category, 0.5), 4
            ),
        }

    # Formato aceito pelo Aggregator do P2:
    # APENAS layer_1 com floats — o Aggregator itera sobre todas as chaves
    # e tenta fazer aritmética em cada valor. Strings e dicts causam crash.
    # local_stats fica disponível apenas no endpoint /data/summary (local).
    layer_1 = [gradients[cat]["local_mean"] for cat in TREATMENT_CATEGORIES]

    log.info(
        f"[{MUNICIPALITY_NAME}] Gradientes calculados: "
        + ", ".join(f"{c}={gradients[c]['local_mean']}" for c in TREATMENT_CATEGORIES)
    )

    # Retorna SOMENTE o que o Aggregator precisa: vetores numéricos por camada
    return {
        "layer_1": layer_1,
    }


async def train_and_callback(round_id: str, model_weights: dict, callback_url: str):
    """
    Task assíncrona: treina localmente e envia gradientes de volta ao P2.

    Simula 2 segundos de "treinamento local" antes de responder.
    Em produção: aqui rodaria o Flower/PyTorch com dados reais.
    """
    log.info(f"[{MUNICIPALITY_NAME}] Iniciando treinamento para rodada {round_id}...")

    # Simula tempo de treinamento local (em produção: epochs de ML aqui)
    await asyncio.sleep(2)

    gradients = compute_local_gradients(model_weights)

    # Chama de volta o P2 com os gradientes
    payload = {
        "municipality_code": MUNICIPALITY_CODE,
        "gradients":         gradients,
    }

    try:
        async with httpx.AsyncClient(timeout=30) as client:
            resp = await client.post(callback_url, json=payload)
            if resp.status_code == 202:
                log.info(f"[{MUNICIPALITY_NAME}] Gradientes entregues ao P2. ✓")
            else:
                log.warning(f"[{MUNICIPALITY_NAME}] P2 respondeu {resp.status_code}: {resp.text}")
    except Exception as e:
        log.error(f"[{MUNICIPALITY_NAME}] Falha ao enviar gradientes: {e}")


# ---------------------------------------------------------------------------
# FastAPI
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    global db
    db = init_db()
    log.info(f"[{MUNICIPALITY_NAME}] Nó FL pronto na porta {PORT}. Aguardando P2...")
    yield
    db.close()


app = FastAPI(
    title=f"FL Node — {MUNICIPALITY_NAME}",
    description="Nó municipal de Federated Learning — Mindala Health",
    version="0.1.0",
    lifespan=lifespan,
)


class TrainRequest(BaseModel):
    round_id:      str
    model_weights: Optional[dict] = {}
    callback_url:  str


class TrainResponse(BaseModel):
    status:            str
    municipality_code: str
    round_id:          str
    message:           str


@app.post("/train", response_model=TrainResponse)
async def trigger_training(req: TrainRequest, background_tasks: BackgroundTasks):
    """
    Recebe modelo do P2, inicia treinamento local em background
    e confirma recebimento imediatamente.

    O P2 não fica bloqueado esperando — o nó chama de volta
    o endpoint /api/v1/fl/rounds/{id}/gradients quando terminar.
    """
    log.info(
        f"[{MUNICIPALITY_NAME}] Modelo recebido para rodada {req.round_id}. "
        f"Callback: {req.callback_url}"
    )

    background_tasks.add_task(
        train_and_callback,
        round_id=req.round_id,
        model_weights=req.model_weights,
        callback_url=req.callback_url,
    )

    return TrainResponse(
        status="training_started",
        municipality_code=MUNICIPALITY_CODE,
        round_id=req.round_id,
        message=f"Treinamento iniciado em {MUNICIPALITY_NAME}. Gradientes em ~2s.",
    )


@app.get("/health")
async def health():
    total = db.execute("SELECT COUNT(*) FROM consultas").fetchone()[0]
    return {
        "status":            "ok",
        "municipality_code": MUNICIPALITY_CODE,
        "municipality_name": MUNICIPALITY_NAME,
        "local_records":     total,
    }


@app.get("/data/summary")
async def data_summary():
    """Resumo dos dados locais — útil para demonstração."""
    rows = db.execute(
        "SELECT tratamento, COUNT(*) as n, ROUND(AVG(efetividade), 3) as media "
        "FROM consultas GROUP BY tratamento ORDER BY media DESC"
    ).fetchall()
    return {
        "municipality_code": MUNICIPALITY_CODE,
        "municipality_name": MUNICIPALITY_NAME,
        "summary": [
            {"tratamento": r[0], "consultas": r[1], "efetividade_media": r[2]}
            for r in rows
        ],
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="info")
