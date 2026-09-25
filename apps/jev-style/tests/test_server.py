"""Tests für src/server.py mit einem Ersatz-Scorer (ohne Modell, ohne llama.cpp)."""

import importlib
import sys
import types
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

SRC = Path(__file__).resolve().parents[1] / "src"
TOKEN = "test-token-123"


class FakeEngine:
    """Liefert deterministische Ergebnisse im Format von JevStyleDecisionGGUF.decide_many."""

    def __init__(self, *args, **kwargs):
        self.calls = []

    def decide_many(self, state, questions, **kwargs):
        self.calls.append((state, questions))
        if state == "too long":
            raise sys.modules["jev_style_decision_gguf"].InputBudgetError("input over budget")
        out = []
        for q in questions:
            if q["t"] == "noul":
                probs = {"false": 0.2, "true": 0.8}
                answer = "true"
            elif q["t"] == "choice":
                names = list(q["crit"])
                probs = {n: (0.7 if i == 0 else 0.3 / (len(names) - 1)) for i, n in enumerate(names)}
                answer = names[0]
            else:
                probs = {str(i): 0.0 for i in range(len(q["crit"]))}
                probs["1"] = 0.5
                probs["2"] = 0.5
                answer = "1"
            out.append({"answer": answer, "probabilities": probs, "entropy_concentration": 0.6,
                        "input_tokens": 42})
        return out

    def close(self):
        pass


@pytest.fixture()
def client(tmp_path, monkeypatch):
    """Lädt server.py mit Ersatz-Runtime und temporärem Token."""
    stub = types.ModuleType("jev_style_decision_gguf")
    stub.InputBudgetError = type("InputBudgetError", (ValueError,), {})
    stub.QuestionError = type("QuestionError", (ValueError,), {})
    stub.JevStyleDecisionGGUF = FakeEngine
    monkeypatch.setitem(sys.modules, "jev_style_decision_gguf", stub)

    token_file = tmp_path / "token"
    token_file.write_text(TOKEN + "\n", encoding="utf-8")
    monkeypatch.setenv("JEV_TOKEN_FILE", str(token_file))
    monkeypatch.setenv("JEV_MODEL_DIR", str(tmp_path))
    monkeypatch.syspath_prepend(str(SRC))
    sys.modules.pop("server", None)
    server = importlib.import_module("server")
    with TestClient(server.app) as c:
        yield c


def auth():
    return {"Authorization": f"Bearer {TOKEN}"}


BODY = {
    "state": "Backup fehlgeschlagen",
    "questions": {
        "act": {"type": "noul", "instructions": "Handeln?"},
        "team": {"type": "choice", "instructions": "Wer?", "criteria": {"ops": "Betrieb", "dev": None}},
        "sev": {"type": "score", "instructions": "Wie schwer?", "criteria": ["a", "b", "c", "d"]},
    },
}


def test_healthz_without_auth(client):
    assert client.get("/healthz").json() == {"ok": True}


@pytest.mark.parametrize("headers", [{}, {"Authorization": "Bearer falsch"}, {"Authorization": TOKEN}])
def test_rejects_missing_or_wrong_token(client, headers):
    assert client.post("/v1/systemone", json=BODY, headers=headers).status_code == 401


def test_maps_all_question_types(client):
    r = client.post("/v1/systemone", json=BODY, headers=auth())
    assert r.status_code == 200
    a = r.json()["answers"]
    assert a["act"] == {"type": "noul", "noul": 0.8}
    assert a["team"]["choice"] == "ops" and a["team"]["confidence"] == 0.6
    assert a["sev"]["score"] == pytest.approx(1.5)
    assert a["sev"]["legend"] == ["a", "b", "c", "d"]
    assert r.json()["usage"] == {"input_tokens": 42, "output_tokens": 0}


def test_choice_list_becomes_dict(client):
    body = {"state": "x", "questions": {"c": {"type": "choice", "instructions": "?", "criteria": ["a", "b"]}}}
    assert client.post("/v1/systemone", json=body, headers=auth()).json()["answers"]["c"]["choice"] == "a"


def test_unknown_type_is_422(client):
    body = {"state": "x", "questions": {"q": {"type": "freitext", "instructions": "?"}}}
    assert client.post("/v1/systemone", json=body, headers=auth()).status_code == 422


def test_too_many_questions_is_422(client):
    qs = {f"q{i}": {"type": "noul", "instructions": "?"} for i in range(17)}
    assert client.post("/v1/systemone", json={"state": "x", "questions": qs}, headers=auth()).status_code == 422


def test_budget_error_is_422(client):
    body = dict(BODY, state="too long")
    r = client.post("/v1/systemone", json=body, headers=auth())
    assert r.status_code == 422 and "budget" in r.json()["detail"]
