"""Order-management API.

Endpoints:
  POST /orders        create an order (idempotent via Idempotency-Key header)
  GET  /orders/{id}   fetch an order
  GET  /health        liveness + DB readiness (ALB / ECS health-check target)
"""

import logging
import uuid
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Header, HTTPException, Request, status
from fastapi.responses import JSONResponse
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError, OperationalError, SQLAlchemyError
from sqlalchemy.orm import Session

from .config import get_settings
from .database import Base, engine, get_db
from .logging_config import configure_logging
from .models import Order
from .schemas import HealthResponse, OrderCreate, OrderResponse

APP_VERSION = "1.0.0"
settings = get_settings()
configure_logging(settings.log_level)
log = logging.getLogger("order-api")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Create tables on startup (Alembic in a real production stack).
    # Wrapped so the task still boots and reports "degraded" via /health if
    # RDS is briefly unreachable — better than crash-looping the ECS task.
    try:
        Base.metadata.create_all(bind=engine)
        log.info("database schema ready")
    except OperationalError as exc:
        log.error("database unavailable at startup: %s", exc.__class__.__name__)
    yield
    engine.dispose()


app = FastAPI(title=settings.app_name, version=APP_VERSION, lifespan=lifespan)


# ---------- middleware: request id + access log --------------------------
@app.middleware("http")
async def request_context(request: Request, call_next):
    # Honour any upstream trace header so we can follow a request across
    # ALB -> app -> logs. Falls back to a fresh UUID otherwise.
    request_id = request.headers.get("x-request-id") or str(uuid.uuid4())
    request.state.request_id = request_id
    response = await call_next(request)
    response.headers["X-Request-ID"] = request_id
    log.info(
        "request",
        extra={
            "request_id": request_id,
            "method": request.method,
            "path": request.url.path,
            "status": response.status_code,
        },
    )
    return response


# ---------- error handling ------------------------------------------------
@app.exception_handler(OperationalError)
async def db_unavailable(request: Request, exc: OperationalError):
    # Connection refused / timeout / pool exhausted -> 503 with Retry-After so
    # ALB and clients treat it as transient, not as a 500 bug.
    log.error(
        "database operational error",
        extra={"request_id": request.state.request_id, "error": exc.__class__.__name__},
    )
    return JSONResponse(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        content={"detail": "database unavailable"},
        headers={"Retry-After": "2"},
    )


@app.exception_handler(SQLAlchemyError)
async def db_error(request: Request, exc: SQLAlchemyError):
    log.exception("database error", extra={"request_id": request.state.request_id})
    return JSONResponse(status_code=500, content={"detail": "internal database error"})


@app.exception_handler(Exception)
async def unhandled(request: Request, exc: Exception):
    log.exception(
        "unhandled error",
        extra={"request_id": getattr(request.state, "request_id", None)},
    )
    return JSONResponse(status_code=500, content={"detail": "internal server error"})


# ---------- endpoints -----------------------------------------------------
@app.get("/health", response_model=HealthResponse, tags=["ops"])
def health(db: Session = Depends(get_db)):
    try:
        db.execute(text("SELECT 1"))
        db_status = "up"
    except OperationalError:
        db_status = "down"
    body = HealthResponse(
        status="ok" if db_status == "up" else "degraded",
        database=db_status,
        version=APP_VERSION,
        environment=settings.app_env,
    )
    # 503 when the DB is down => the ALB target group marks the task
    # unhealthy and stops routing traffic to it.
    code = 200 if db_status == "up" else 503
    return JSONResponse(status_code=code, content=body.model_dump())


@app.post(
    "/orders",
    response_model=OrderResponse,
    status_code=status.HTTP_201_CREATED,
    tags=["orders"],
)
def create_order(
    payload: OrderCreate,
    response: JSONResponse,
    db: Session = Depends(get_db),
    idempotency_key: str | None = Header(default=None, max_length=64),
):
    # Fast path: reuse the same order for a repeated key.
    if idempotency_key:
        existing = db.query(Order).filter(Order.idempotency_key == idempotency_key).first()
        if existing:
            response.status_code = status.HTTP_200_OK
            log.info("idempotent replay", extra={"order_id": existing.id})
            return existing

    order = Order(
        customer_email=payload.customer_email,
        items=[i.model_dump(mode="json") for i in payload.items],
        total_amount=payload.total,
        idempotency_key=idempotency_key,
    )
    db.add(order)
    try:
        db.commit()
    except IntegrityError:
        # Race: two concurrent requests with the same key.
        # The DB unique constraint wins; return the row the other request created.
        db.rollback()
        existing = db.query(Order).filter(Order.idempotency_key == idempotency_key).first()
        if existing:
            response.status_code = status.HTTP_200_OK
            return existing
        raise
    db.refresh(order)
    log.info(
        "order created",
        extra={"order_id": order.id, "total": str(order.total_amount)},
    )
    return order


@app.get("/orders/{order_id}", response_model=OrderResponse, tags=["orders"])
def get_order(order_id: str, db: Session = Depends(get_db)):
    try:
        uuid.UUID(order_id)
    except ValueError as e:
        raise HTTPException(status_code=422, detail="order_id must be a UUID") from e
    order = db.get(Order, order_id)
    if not order:
        raise HTTPException(status_code=404, detail="order not found")
    return order
