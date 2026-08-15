#!/usr/bin/env bash
# DB-24(복제 지연 / read-your-writes) 검증용 스트리밍 레플리카를 로컬에 만든다.
# Docker 없이 Debian/Ubuntu 의 PostgreSQL 클러스터 도구만 쓴다 —
# 이 세션에서 이 방식으로 DB-24 를 INCONCLUSIVE → CONFIRMED 로 바꿨다.
#
#   ./scripts/verify/setup-replica.sh          # 생성 + 기동
#   ./scripts/verify/setup-replica.sh drop     # 제거
#
# 선행 조건: 프라이머리(5432)가 떠 있고, verifylab 롤에 REPLICATION 속성이 있을 것
#            (setup-verifylab.sh 가 붙여 준다). pg_hba 에 host replication 항목도 필요하다
#            — Debian 기본 설정에 127.0.0.1/::1 용으로 이미 들어 있다.
set -euo pipefail

VER="${PG_VERSION:-16}"
CLUSTER="${REPLICA_CLUSTER:-replica}"
PRIMARY_PORT="${PGPORT:-5432}"
DATA="/var/lib/postgresql/$VER/$CLUSTER"
CONF="/etc/postgresql/$VER/$CLUSTER/postgresql.conf"

drop(){
  pg_ctlcluster "$VER" "$CLUSTER" stop 2>/dev/null || true
  pg_dropcluster "$VER" "$CLUSTER" 2>/dev/null || true
  echo "레플리카 클러스터 제거됨"
  exit 0
}
[ "${1:-}" = "drop" ] && drop

# 1) 클러스터 골격 (포트는 pg_createcluster 가 비어 있는 것으로 배정한다 — 보통 5433)
if [ ! -f "$CONF" ]; then
  pg_createcluster "$VER" "$CLUSTER" >/dev/null
fi
REPLICA_PORT=$(awk -F'[ \t=]+' '/^port/{print $2}' "$CONF")
pg_ctlcluster "$VER" "$CLUSTER" stop 2>/dev/null || true

# 2) 베이스백업으로 복제본을 만든다 (-R 이 standby.signal 과 primary_conninfo 를 써 준다)
sudo -u postgres bash -c "cat > ~/.pgpass <<'PGP'
localhost:$PRIMARY_PORT:replication:verifylab:verifylab
localhost:$PRIMARY_PORT:*:verifylab:verifylab
PGP
chmod 600 ~/.pgpass"
rm -rf "${DATA:?}"/*
sudo -u postgres env PGPASSWORD=verifylab pg_basebackup \
    -h localhost -p "$PRIMARY_PORT" -U verifylab -D "$DATA" -Fp -Xs -R

# 3) 관측 창을 여는 설정
if ! grep -q recovery_min_apply_delay "$CONF"; then
  cat >> "$CONF" <<'EOF'

# ── DB-24(복제 지연 / read-your-writes) 검증용 ──────────────────────────
hot_standby = on
# 프라이머리와 레플리카가 같은 호스트면 복제가 수 ms 안에 따라잡아 '쓰기 직후 옛 값이
# 보인다'는 현상을 관측할 창 자체가 열리지 않는다(실제로 INCONCLUSIVE 가 났다).
# WAL 재생을 실제로 늦추는 PostgreSQL 정식 기능이므로, 결과를 만드는 것이 아니라
# 실무에서 불규칙하게 일어나는 지연을 관측 가능한 크기로 고정하는 것이다.
recovery_min_apply_delay = '2s'
EOF
fi

pg_ctlcluster "$VER" "$CLUSTER" start
sleep 3
echo "레플리카 기동 (포트 $REPLICA_PORT)"
PGPASSWORD=verifylab psql -h localhost -p "$REPLICA_PORT" -U verifylab -d verifylab -X -tAc \
  "SELECT '  recovery=' || pg_is_in_recovery() || ' delay=' || current_setting('recovery_min_apply_delay')"
echo
echo "검증:"
echo "  ./gradlew :verify-lab:test -Dverify.only=DB-24"
[ "$REPLICA_PORT" != "5433" ] && echo "  ※ 포트가 5433 이 아니므로 REPLICA_PORT=$REPLICA_PORT 를 넘겨야 한다"
exit 0
