"""Application configuration.

All settings come from environment variables (12-factor). Nothing is hardcoded,
so the same image runs locally (docker compose), in CI, and on ECS Fargate.
On AWS the DB password is injected by ECS from AWS Secrets Manager into the
DB_PASSWORD env var — the app never talks to Secrets Manager directly.
"""

from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_name: str = "order-api"
    app_env: str = Field(default="local", description="local | dev | staging | prod")
    log_level: str = "INFO"

    db_host: str = "localhost"
    db_port: int = 5432
    db_name: str = "orders"
    db_user: str = "orders"
    db_password: str = Field(default="", repr=False)  # repr=False keeps it out of logs

    # Bounded pool so total RDS connections = tasks * (pool_size + max_overflow).
    # Predictability matters when Lambda (which opens a connection per concurrent
    # execution) is being replaced by long-lived containers.
    db_pool_size: int = 5
    db_max_overflow: int = 5
    db_pool_timeout: int = 5  # seconds a request will wait for a free conn
    db_connect_timeout: int = 3  # TCP-level connect timeout

    @property
    def database_url(self) -> str:
        return (
            f"postgresql+psycopg://{self.db_user}:{self.db_password}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
        )


@lru_cache
def get_settings() -> Settings:
    return Settings()
