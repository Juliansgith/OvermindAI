import os
from typing import Any

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine


def get_engine() -> Engine:
    host = os.getenv("AUTOTUNE_DB_HOST", "localhost")
    port = int(os.getenv("AUTOTUNE_DB_PORT", "54329"))
    name = os.getenv("AUTOTUNE_DB_NAME", "overmind_autotune")
    user = os.getenv("AUTOTUNE_DB_USER", "overmind")
    password = os.getenv("AUTOTUNE_DB_PASSWORD", "overmind_dev")
    url = f"postgresql+psycopg2://{user}:{password}@{host}:{port}/{name}"
    return create_engine(url, pool_pre_ping=True)


def read_sql(engine: Engine, query: str, params: dict[str, Any] | None = None) -> pd.DataFrame:
    with engine.connect() as connection:
        return pd.read_sql_query(text(query), connection, params=params or {})
