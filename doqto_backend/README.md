# Doqto Backend

FastAPI + PostgreSQL 15 + Redis 7 + AWS (S3, Transcribe Medical) + Firebase Auth.

## Quick Start (local)

```bash
cp .env.example .env
# Edit SUPER_ADMIN_PHONE if desired

# Start local Postgres + Redis
docker compose up -d

# Install deps + run migrations
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt
alembic upgrade head

# Run API
uvicorn main:app --reload --port 8000
# Swagger: http://localhost:8000/docs
```

## Architecture

- `app/core/` — config, enums (StrEnum), constants, Redis keys, API paths, security (JWT + AES-GCM)
- `app/db/` — SQLAlchemy async engine, Redis client, table-name constants
- `app/models/` — ORM for all 8 tables
- `app/schemas/` — Pydantic I/O models
- `app/services/` — business logic (static-method classes)
- `app/api/v1/` — REST routers
- `app/api/websocket.py` — `/ws/{org_id}` real-time endpoint
- `alembic/` — migrations (0001 init, 0002 super-admin seed)

## Single Source of Truth

Never inline constants, enum strings, Redis keys, or API paths. Always reference:

- `app.core.enums` for any enum wire value (mirrored in `docs/enums.md` + Flutter)
- `app.core.constants` for TTLs, limits, page sizes
- `app.core.redis_keys` for any Redis key
- `app.core.routes` for any path
- `app.db.tables` for any table name
