"""
NorthPay Ledger API
-------------------
A minimal payments ledger demonstrating production-style FastAPI patterns:
 - EKS Pod Identity for AWS access (no credentials in the container)
 - PostgreSQL via connection string from AWS Secrets Manager (External Secrets Operator)
 - Structured JSON logging
 - /healthz and /readyz probes
 - Prometheus metrics via prometheus-fastapi-instrumentator
"""

import logging
import os
import uuid
from contextlib import asynccontextmanager
from decimal import Decimal
from typing import Annotated

import structlog
from fastapi import FastAPI, HTTPException, Header, status
from fastapi.middleware.cors import CORSMiddleware
from prometheus_fastapi_instrumentator import Instrumentator
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy import text

# ── Logging ───────────────────────────────────────────────────────────────────

structlog.configure(
    processors=[
        structlog.stdlib.add_log_level,
        structlog.stdlib.add_logger_name,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer(),
    ]
)
logger = structlog.get_logger()

# ── Database ──────────────────────────────────────────────────────────────────

DATABASE_URL = os.environ["DATABASE_URL"]  # injected by External Secrets Operator

engine = create_async_engine(DATABASE_URL, echo=False, pool_pre_ping=True)
AsyncSessionLocal = sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


async def get_db() -> AsyncSession:  # type: ignore
    async with AsyncSessionLocal() as session:
        yield session


# ── Models ────────────────────────────────────────────────────────────────────


class PaymentRequest(BaseModel):
    source_account: str = Field(..., min_length=1, max_length=64)
    destination_account: str = Field(..., min_length=1, max_length=64)
    amount: Decimal = Field(..., gt=0, decimal_places=2)
    currency: str = Field(default="USD", pattern="^[A-Z]{3}$")
    idempotency_key: str = Field(..., min_length=1, max_length=128)


class PaymentResponse(BaseModel):
    payment_id: str
    status: str
    source_account: str
    destination_account: str
    amount: Decimal
    currency: str


class BalanceResponse(BaseModel):
    account_id: str
    balance: Decimal
    currency: str


# ── Lifespan ──────────────────────────────────────────────────────────────────


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Create tables on startup (use Alembic for real migrations)
    async with engine.begin() as conn:
        await conn.execute(text("""
            CREATE TABLE IF NOT EXISTS accounts (
                account_id TEXT PRIMARY KEY,
                balance    NUMERIC(18,2) NOT NULL DEFAULT 0,
                currency   CHAR(3)       NOT NULL DEFAULT 'USD'
            )
        """))
        await conn.execute(text("""
            CREATE TABLE IF NOT EXISTS payments (
                payment_id       TEXT PRIMARY KEY,
                source_account   TEXT        NOT NULL,
                destination_account TEXT     NOT NULL,
                amount           NUMERIC(18,2) NOT NULL,
                currency         CHAR(3)     NOT NULL,
                idempotency_key  TEXT        NOT NULL UNIQUE,
                status           TEXT        NOT NULL DEFAULT 'completed',
                created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        """))
    logger.info("database.ready")
    yield
    await engine.dispose()


# ── App ───────────────────────────────────────────────────────────────────────

app = FastAPI(
    title="NorthPay Ledger API",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

Instrumentator().instrument(app).expose(app)


# ── Routes ────────────────────────────────────────────────────────────────────


@app.get("/healthz")
async def healthz():
    """Liveness probe — always returns 200 while the process is alive."""
    return {"status": "ok"}


@app.get("/readyz")
async def readyz():
    """Readiness probe — checks DB connectivity before accepting traffic."""
    try:
        async with AsyncSessionLocal() as session:
            await session.execute(text("SELECT 1"))
        return {"status": "ready"}
    except Exception as exc:
        logger.error("readyz.failed", error=str(exc))
        raise HTTPException(status_code=503, detail="database unavailable")


@app.post("/payments", response_model=PaymentResponse, status_code=status.HTTP_201_CREATED)
async def create_payment(
    payment: PaymentRequest,
    x_request_id: Annotated[str | None, Header()] = None,
):
    """
    Transfer funds between two accounts.
    Idempotent: re-submitting the same idempotency_key returns the original payment.
    """
    request_id = x_request_id or str(uuid.uuid4())
    log = logger.bind(request_id=request_id, idempotency_key=payment.idempotency_key)

    async with AsyncSessionLocal() as session:
        # Idempotency check
        existing = await session.execute(
            text("SELECT payment_id, status, amount FROM payments WHERE idempotency_key = :key"),
            {"key": payment.idempotency_key},
        )
        row = existing.fetchone()
        if row:
            log.info("payment.duplicate", payment_id=row.payment_id)
            return PaymentResponse(
                payment_id=row.payment_id,
                status=row.status,
                source_account=payment.source_account,
                destination_account=payment.destination_account,
                amount=row.amount,
                currency=payment.currency,
            )

        # Check source balance
        balance_row = await session.execute(
            text("SELECT balance FROM accounts WHERE account_id = :id FOR UPDATE"),
            {"id": payment.source_account},
        )
        balance = balance_row.fetchone()
        if not balance or balance.balance < payment.amount:
            raise HTTPException(status_code=422, detail="insufficient funds")

        payment_id = str(uuid.uuid4())

        async with session.begin():
            await session.execute(
                text("UPDATE accounts SET balance = balance - :amt WHERE account_id = :id"),
                {"amt": payment.amount, "id": payment.source_account},
            )
            await session.execute(
                text("UPDATE accounts SET balance = balance + :amt WHERE account_id = :id"),
                {"amt": payment.amount, "id": payment.destination_account},
            )
            await session.execute(
                text("""
                    INSERT INTO payments
                      (payment_id, source_account, destination_account, amount, currency, idempotency_key)
                    VALUES (:pid, :src, :dst, :amt, :cur, :key)
                """),
                {
                    "pid": payment_id,
                    "src": payment.source_account,
                    "dst": payment.destination_account,
                    "amt": payment.amount,
                    "cur": payment.currency,
                    "key": payment.idempotency_key,
                },
            )

        log.info("payment.created", payment_id=payment_id, amount=str(payment.amount))
        return PaymentResponse(
            payment_id=payment_id,
            status="completed",
            source_account=payment.source_account,
            destination_account=payment.destination_account,
            amount=payment.amount,
            currency=payment.currency,
        )


@app.get("/balance/{account_id}", response_model=BalanceResponse)
async def get_balance(account_id: str):
    """Return the current balance for an account."""
    async with AsyncSessionLocal() as session:
        result = await session.execute(
            text("SELECT balance, currency FROM accounts WHERE account_id = :id"),
            {"id": account_id},
        )
        row = result.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="account not found")
        return BalanceResponse(account_id=account_id, balance=row.balance, currency=row.currency)
