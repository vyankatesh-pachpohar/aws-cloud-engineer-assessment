import uuid
from datetime import datetime, timezone

from sqlalchemy import JSON, DateTime, Numeric, String
from sqlalchemy.orm import Mapped, mapped_column

from .database import Base


class Order(Base):
    __tablename__ = "orders"

    id: Mapped[str] = mapped_column(
        String(36), primary_key=True, default=lambda: str(uuid.uuid4())
    )
    customer_email: Mapped[str] = mapped_column(String(255), nullable=False, index=True)
    items: Mapped[list] = mapped_column(JSON, nullable=False)
    total_amount: Mapped[float] = mapped_column(Numeric(12, 2), nullable=False)
    status: Mapped[str] = mapped_column(String(32), nullable=False, default="CREATED")

    # Client-supplied key (Idempotency-Key header). The DB unique constraint is
    # the real guarantee against duplicate orders under retries / concurrent
    # writes — critical during the Lambda->ECS traffic-shift migration.
    idempotency_key: Mapped[str | None] = mapped_column(
        String(64), unique=True, nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        default=lambda: datetime.now(timezone.utc),
    )
