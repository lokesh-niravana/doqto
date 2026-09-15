#!/bin/bash
# Wipe application data from PROD Postgres and start clean.
#
# The DB (RDS `doqto-backend`) only accepts connections from the app security
# group, so the SQL runs inside a one-off ECS task on the same task definition
# as the API — it already carries DATABASE_URL and the SUPER_ADMIN_* vars.
# A one-off task is used rather than `ecs execute-command` because exec needs
# the AWS session-manager-plugin, whose installer requires sudo on a TTY.
#
# Safety:
#   * takes a manual RDS snapshot first and WAITS for it. Automated backups
#     keep 7 days; this named snapshot is the thing you restore from.
#   * refuses to run without CONFIRM=DELETE_PROD in the environment
#   * one transaction; alembic_version is preserved so the schema stays valid
#   * re-seeds the super admin, which migrations 0002/0005 would otherwise be
#     relied on for — and they will not re-run, because alembic_version stays
#
# Usage: CONFIRM=DELETE_PROD scripts/prod_reset_data.sh users|all
#   users = users and everything hanging off them (organizations survive)
#   all   = every table except alembic_version
set -euo pipefail

SCOPE="${1:-}"
[[ "$SCOPE" == "users" || "$SCOPE" == "all" ]] || { echo "usage: CONFIRM=DELETE_PROD $0 users|all" >&2; exit 1; }
[ "${CONFIRM:-}" = "DELETE_PROD" ] || { echo "refusing: set CONFIRM=DELETE_PROD" >&2; exit 1; }

CLUSTER=doqto-backend
TASKDEF=doqto-backend
CONTAINER=api
DB=doqto-backend
LOG_GROUP=/ecs/doqto-backend
SUBNET=subnet-025a172a80f74eeaf
SG=sg-0d70a36a945464800
# Prod is account 943014910992, NOT the `default` profile (677841334265).
export AWS_PROFILE="${AWS_PROFILE:-loki-doqto}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

echo "== account $(aws sts get-caller-identity --query Account --output text) | scope $SCOPE"

SNAP="doqto-backend-prewipe-$(date +%Y%m%d-%H%M)"
echo "== snapshot $SNAP (a few minutes)"
aws rds create-db-snapshot --db-instance-identifier "$DB" --db-snapshot-identifier "$SNAP" >/dev/null
aws rds wait db-snapshot-available --db-snapshot-identifier "$SNAP"
echo "== snapshot available: $SNAP"

# CASCADE resolves foreign-key order, so the table list is never maintained by hand.
if [ "$SCOPE" = users ]; then
  SQL="TRUNCATE TABLE users RESTART IDENTITY CASCADE;"
else
  SQL="DO \$do\$ DECLARE t text; BEGIN FOR t IN SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename <> 'alembic_version' LOOP EXECUTE format('TRUNCATE TABLE %I RESTART IDENTITY CASCADE', t); END LOOP; END \$do\$;"
fi

read -r -d '' PY <<PYEOF || true
import asyncio, os, asyncpg
from passlib.context import CryptContext

async def main():
    url = os.environ["DATABASE_URL"].replace("postgresql+asyncpg://", "postgresql://")
    c = await asyncpg.connect(url)
    before = await c.fetchval("SELECT count(*) FROM users")
    async with c.transaction():
        await c.execute("""$SQL""")
        # The super admin is a users row seeded by migrations 0002/0005. Those
        # will not re-run (alembic_version survives), so re-seed it here or the
        # admin panel is locked out.
        phone = os.environ.get("SUPER_ADMIN_PHONE", "").strip()
        if phone:
            await c.execute(
                "INSERT INTO users (phone, full_name, npi_number, role) "
                "VALUES (\$1, \$2, \$3, 'super_admin') ON CONFLICT (phone) DO NOTHING",
                phone,
                os.environ.get("SUPER_ADMIN_NAME", "Platform Admin").strip(),
                os.environ.get("SUPER_ADMIN_NPI", "0000000001").strip())
            email = os.environ.get("SUPER_ADMIN_EMAIL", "").strip().lower()
            pw = os.environ.get("SUPER_ADMIN_PASSWORD", "")
            if email and pw:
                h = CryptContext(schemes=["bcrypt"], deprecated="auto").hash(pw)
                await c.execute(
                    "UPDATE users SET email = \$1, password_hash = \$2 "
                    "WHERE phone = \$3 AND role = 'super_admin'", email, h, phone)
            print("RESET super admin re-seeded:", phone)
        else:
            print("RESET WARNING SUPER_ADMIN_PHONE unset - admin panel has no login")
    after = await c.fetchval("SELECT count(*) FROM users")
    rows = await c.fetch("SELECT relname, n_live_tup FROM pg_stat_user_tables "
                         "WHERE n_live_tup > 0 ORDER BY n_live_tup DESC")
    print("RESET users:", before, "->", after)
    print("RESET non-empty tables:", [(r[0], r[1]) for r in rows] or "none")
    await c.close()

asyncio.run(main())
PYEOF

OVERRIDES=$(python3 -c '
import json, sys
print(json.dumps({"containerOverrides": [{"name": sys.argv[1], "command": ["python", "-c", sys.argv[2]]}]}))
' "$CONTAINER" "$PY")

echo "== running one-off task"
TASK=$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$TASKDEF" --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET],securityGroups=[$SG],assignPublicIp=ENABLED}" \
  --overrides "$OVERRIDES" --query 'tasks[0].taskArn' --output text)
ID="${TASK##*/}"
echo "== task $ID"
aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$TASK"

CODE=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK" \
        --query 'tasks[0].containers[0].exitCode' --output text)
echo "== exit code $CODE"
aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$CONTAINER/$CONTAINER/$ID" \
  --query 'events[*].message' --output text | tr '\t' '\n' | grep -E "RESET|Error|Traceback|error" || \
  echo "(no RESET lines; check $LOG_GROUP stream $CONTAINER/$CONTAINER/$ID)"

echo
echo "== restore point: $SNAP"
echo "== NOT touched: S3 media objects, Redis sessions (signed-in devices keep valid tokens until expiry)"
