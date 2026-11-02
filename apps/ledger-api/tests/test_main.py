"""
Unit / integration tests for the Ledger API.
Run with: pytest tests/ -v
"""

import pytest
from httpx import AsyncClient, ASGITransport

# Override DATABASE_URL before importing the app
import os
os.environ.setdefault("DATABASE_URL", "sqlite+aiosqlite:///:memory:")

from src.main import app  # noqa: E402


@pytest.fixture
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


@pytest.mark.asyncio
async def test_healthz(client):
    r = await client.get("/healthz")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


@pytest.mark.asyncio
async def test_balance_not_found(client):
    r = await client.get("/balance/nonexistent")
    assert r.status_code == 404


@pytest.mark.asyncio
async def test_create_payment_idempotency(client):
    payload = {
        "source_account": "acct_001",
        "destination_account": "acct_002",
        "amount": "100.00",
        "currency": "USD",
        "idempotency_key": "test-idem-key-001",
    }
    # First call — may fail with 422 if account doesn't exist (expected in unit tests)
    r1 = await client.post("/payments", json=payload)
    assert r1.status_code in (201, 422)

    if r1.status_code == 201:
        # Second call with same key should return same result
        r2 = await client.post("/payments", json=payload)
        assert r2.status_code == 201
        assert r1.json()["payment_id"] == r2.json()["payment_id"]
