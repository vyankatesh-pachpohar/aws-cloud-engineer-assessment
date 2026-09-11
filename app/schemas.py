from datetime import datetime
from decimal import Decimal

from pydantic import BaseModel, EmailStr, Field, field_validator


class OrderItem(BaseModel):
    sku: str = Field(min_length=1, max_length=64)
    quantity: int = Field(gt=0, le=1000)
    unit_price: Decimal = Field(gt=0, decimal_places=2)


class OrderCreate(BaseModel):
    customer_email: EmailStr
    items: list[OrderItem] = Field(min_length=1, max_length=100)

    @field_validator("items")
    @classmethod
    def unique_skus(cls, items: list[OrderItem]) -> list[OrderItem]:
        skus = [i.sku for i in items]
        if len(skus) != len(set(skus)):
            raise ValueError("duplicate SKU in items")
        return items

    @property
    def total(self) -> Decimal:
        return sum((i.unit_price * i.quantity for i in self.items), Decimal("0"))


class OrderResponse(BaseModel):
    id: str
    customer_email: str
    items: list[OrderItem]
    total_amount: Decimal
    status: str
    created_at: datetime

    model_config = {"from_attributes": True}


class HealthResponse(BaseModel):
    status: str
    database: str
    version: str
    environment: str
