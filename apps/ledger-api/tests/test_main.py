"""
Unit / integration tests for the Ledger API.
Run with: pytest tests/ -v

Uses Starlette's TestClient which correctly runs the app lifespan
(startup/shutdown hooks), so the database tables are created before tests run.
DATABASE_URL is overridden to SQLite in-memory so no real DB is needed.
"""

import asyncio
import os
import pytest
from sqlalchemy import text

os.environ["DATABASE_URL"] = "sqlite+aiosqlite:///:memory:"

from starlette.testclient import TestClient  # noqa: E402
from src.main import app, engine  # noqa: E402


@pytest.fixture(scope="module")
def client():
    """Module-scoped so the in-memory DB persists across all tests."""
    with TestClient(app, raise_server_exceptions=True) as c:
        yield c


def seed(rows: list[tuple]):
    """Insert account rows directly, bypassing the API. Thread-safe via asyncio.run."""
    async def _insert():
        async with engine.begin() as conn:
            for account_id, balance in rows:
                await conn.execute(
                    text(
                        "INSERT OR IGNORE INTO accounts"
                        " (account_id, balance, currency) VALUES (:id, :bal, 'USD')"
                    ),
                    {"id": account_id, "bal": balance},
                )
    asyncio.run(_insert())


# ── Tests ─────────────────────────────────────────────────────────────────────

def test_healthz(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_readyz(client):
    r = client.get("/readyz")
    assert r.status_code == 200
    assert r.json()["status"] == "ready"


def test_balance_not_found(client):
    r = client.get("/balance/no-such-account")
    assert r.status_code == 404


def test_create_payment_insufficient_funds(client):
    """Payment from an account with zero balance returns 422."""
    r = client.post("/payments", json={
        "source_account": "empty-account",
        "destination_account": "dest-account",
        "amount": "10.00",
        "currency": "USD",
        "idempotency_key": "test-insufficient-001",
    })
    assert r.status_code == 422


def test_create_payment_success_and_balance(client):
    """Successful payment adjusts both account balances correctly."""
    seed([("src-a", 500), ("dst-a", 0)])

    r = client.post("/payments", json={
        "source_account": "src-a",
        "destination_account": "dst-a",
        "amount": "150.00",
        "currency": "USD",
        "idempotency_key": "test-success-a001",
    })
    assert r.status_code == 201
    body = r.json()
    assert body["status"] == "completed"
    assert body["amount"] == "150.00"
    assert "payment_id" in body

    assert float(client.get("/balance/src-a").json()["balance"]) == 350.0
    assert float(client.get("/balance/dst-a").json()["balance"]) == 150.0


def test_create_payment_idempotency(client):
    """Submitting the same idempotency_key twice returns the original payment_id."""
    seed([("src-b", 1000), ("dst-b", 0)])

    payload = {
        "source_account": "src-b",
        "destination_account": "dst-b",
        "amount": "75.00",
        "currency": "USD",
        "idempotency_key": "test-idem-b001",
    }

    r1 = client.post("/payments", json=payload)
    assert r1.status_code == 201
    pid = r1.json()["payment_id"]

    r2 = client.post("/payments", json=payload)
    assert r2.status_code == 201
    assert r2.json()["payment_id"] == pid  # same ID, not a second debit
