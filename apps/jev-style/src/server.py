"""TypeSafe-kompatibler System-One-Server vor Jev-Style-0.8B-Decision-v3 (GGUF, llama.cpp, CPU).

Endpunkte:
    GET  /healthz        ohne Auth, nur {"ok": true}
    POST /v1/systemone   Bearer-Token, Request/Response wie https://docs.typesafe.ai/api.md

Der Scorer ist ein einzelner JSON-lines-Prozess und nicht threadsicher, daher serialisiert ein Lock
alle Anfragen. Umgebungsvariablen: JEV_MODEL_DIR, JEV_QUANT, JEV_TOKEN_FILE, JEV_THREADS, JEV_MAX_QUESTIONS.
"""

import hmac
import json
import os
import sys
import threading
from contextlib import asynccontextmanager
from typing import Any, Dict, Optional, Union

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

MODEL_DIR = os.environ.get("JEV_MODEL_DIR", "/opt/jev-style/model")
QUANT = os.environ.get("JEV_QUANT", "Q8_0")
TOKEN_FILE = os.environ.get("JEV_TOKEN_FILE", "/etc/jev-style/token")
_CPUS = len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else (os.cpu_count() or 2)
THREADS = int(os.environ.get("JEV_THREADS", str(_CPUS)))  # im LXC die zugeteilten Kerne, nicht die des Hosts
MAX_QUESTIONS = int(os.environ.get("JEV_MAX_QUESTIONS", "16"))
MODEL_LABEL = "jev-style-0.8b-v3-" + QUANT.lower()

sys.path.insert(0, MODEL_DIR)
from jev_style_decision_gguf import (  # noqa: E402  (Pfad erst zur Laufzeit bekannt)
    InputBudgetError,
    JevStyleDecisionGGUF,
    QuestionError,
)

_engine: Optional[JevStyleDecisionGGUF] = None
_lock = threading.Lock()


def _load_token() -> str:
    """Liest das API-Token; ohne Token startet der Server nicht."""
    with open(TOKEN_FILE, encoding="utf-8") as fh:
        token = fh.read().strip()
    if not token:
        raise RuntimeError(f"Leeres Token in {TOKEN_FILE}")
    return token


API_TOKEN = _load_token()


@asynccontextmanager
async def lifespan(_: FastAPI):
    """Startet den Scorer-Prozess einmal beim Hochfahren und beendet ihn sauber."""
    global _engine
    _engine = JevStyleDecisionGGUF(MODEL_DIR, quant=QUANT, n_gpu_layers=0, threads=THREADS, verify=True)
    try:
        yield
    finally:
        _engine.close()


app = FastAPI(title="Jev-Style System One", docs_url=None, redoc_url=None, lifespan=lifespan)


class Question(BaseModel):
    """Eine typisierte Frage im TypeSafe-Format."""

    type: str = Field(pattern="^(noul|choice|score)$")
    instructions: Union[str, Dict[str, Any], list]
    criteria: Optional[Union[Dict[str, Optional[str]], list]] = None


class SystemOneRequest(BaseModel):
    """Request-Body von POST /v1/systemone."""

    state: Union[str, Dict[str, Any], list]
    model: Optional[str] = None
    questions: Dict[str, Question]


def require_token(authorization: str = Header(default="")) -> None:
    """Prüft den Bearer-Token zeitkonstant."""
    scheme, _, value = authorization.partition(" ")
    if scheme.lower() != "bearer" or not hmac.compare_digest(value.strip(), API_TOKEN):
        raise HTTPException(status_code=401, detail="invalid or missing API key")


def to_runtime_question(q: Question) -> dict:
    """Übersetzt eine TypeSafe-Frage in das Runtime-Format {"t", "ins", "crit"}."""
    ins = q.instructions if isinstance(q.instructions, str) else json.dumps(q.instructions, ensure_ascii=False)
    crit = q.criteria
    if q.type == "choice" and isinstance(crit, list):
        crit = {str(o): None for o in crit}
    return {"t": q.type, "ins": ins, "crit": crit}


def to_answer(qtype: str, crit: Any, result: dict) -> dict:
    """Formt ein Runtime-Ergebnis in die TypeSafe-Antwortstruktur um.

    confidence = entropy_concentration der Runtime (0 = gleichverteilt, 1 = eindeutig).
    score = erwarteter Level-Index (0 .. n-1), kann zwischen zwei Stufen liegen.
    """
    probs = result["probabilities"]
    if qtype == "noul":
        return {"type": "noul", "noul": probs["true"]}
    if qtype == "choice":
        return {"type": "choice", "choice": result["answer"], "probabilities": probs,
                "confidence": result["entropy_concentration"]}
    expected = sum(int(level) * p for level, p in probs.items())
    return {"type": "score", "score": expected, "legend": crit, "probabilities": probs,
            "confidence": result["entropy_concentration"]}


@app.get("/healthz")
def healthz() -> dict:
    """Lebenszeichen ohne Details."""
    return {"ok": _engine is not None}


@app.post("/v1/systemone", dependencies=[Depends(require_token)])
def system_one(req: SystemOneRequest) -> dict:
    """Beantwortet alle Fragen zu einem State in einem Scorer-Aufruf."""
    if not req.questions:
        raise HTTPException(status_code=422, detail="questions must not be empty")
    if len(req.questions) > MAX_QUESTIONS:
        raise HTTPException(status_code=422, detail=f"at most {MAX_QUESTIONS} questions per request")

    names = list(req.questions)
    runtime_qs = [to_runtime_question(req.questions[n]) for n in names]
    try:
        with _lock:
            results = _engine.decide_many(req.state, runtime_qs)
    except (InputBudgetError, QuestionError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from None

    answers = {n: to_answer(q["t"], q["crit"], r) for n, q, r in zip(names, runtime_qs, results)}
    input_tokens = max((r.get("input_tokens", 0) for r in results), default=0)
    return {"model": MODEL_LABEL, "answers": answers,
            "usage": {"input_tokens": input_tokens, "output_tokens": 0}}
