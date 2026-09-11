import uuid

VALID = {
    "customer_email": "a@example.com",
    "items": [
        {"sku": "ABC-1", "quantity": 2, "unit_price": "10.50"},
        {"sku": "XYZ-9", "quantity": 1, "unit_price": "4.00"},
    ],
}


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["database"] == "up"
    assert "X-Request-ID" in r.headers


def test_create_and_get_order(client):
    r = client.post("/orders", json=VALID)
    assert r.status_code == 201
    body = r.json()
    assert body["status"] == "CREATED"
    assert body["total_amount"] == "25.00"
    uuid.UUID(body["id"])
    g = client.get(f"/orders/{body['id']}")
    assert g.status_code == 200
    assert g.json()["customer_email"] == "a@example.com"


def test_validation_errors(client):
    assert client.post("/orders", json={**VALID, "customer_email": "nope"}).status_code == 422
    assert client.post("/orders", json={**VALID, "items": []}).status_code == 422
    neg = client.post(
        "/orders",
        json={
            "customer_email": "a@b.com",
            "items": [{"sku": "A", "quantity": 0, "unit_price": "1"}],
        },
    )
    assert neg.status_code == 422
    dup_sku = client.post(
        "/orders",
        json={
            "customer_email": "a@b.com",
            "items": [
                {"sku": "A", "quantity": 1, "unit_price": "1"},
                {"sku": "A", "quantity": 1, "unit_price": "1"},
            ],
        },
    )
    assert dup_sku.status_code == 422


def test_get_missing_and_bad_id(client):
    assert client.get(f"/orders/{uuid.uuid4()}").status_code == 404
    assert client.get("/orders/not-a-uuid").status_code == 422


def test_idempotency_key_prevents_duplicates(client):
    key = "order-7f3a"
    first = client.post("/orders", json=VALID, headers={"Idempotency-Key": key})
    second = client.post("/orders", json=VALID, headers={"Idempotency-Key": key})
    assert first.status_code == 201
    assert second.status_code == 200  # replay, not a new order
    assert first.json()["id"] == second.json()["id"]


def test_db_failure_returns_503(client, monkeypatch):
    from sqlalchemy.exc import OperationalError

    from app import main

    def boom(*a, **k):
        raise OperationalError("SELECT 1", {}, Exception("connection refused"))

    monkeypatch.setattr(main.Session, "execute", boom)
    r = client.get("/health")
    assert r.status_code == 503
    assert r.json()["database"] == "down"
