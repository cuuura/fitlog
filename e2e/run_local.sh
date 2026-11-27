#!/usr/bin/env bash
# 로컬/CI 용 E2E 실행기: 서버를 빌드해 실제 프로세스로 띄우고, 중간에 재시작하며 e2e/run.py 를 두 번 돌린다.
#
#   e2e/run_local.sh
#
# 환경 변수(모두 선택):
#   E2E_PORT          서버 포트(기본 18080)
#   PG_HOST/PG_PORT   PostgreSQL 주소(기본 localhost:5432)
#   PG_USER/PG_PASSWORD  슈퍼유저(기본 fitlog/fitlog). DB 를 지우고 다시 만들 수 있어야 한다
#   E2E_DB            테스트 DB 이름(기본 fitlog_e2e). 실행 때마다 지우고 새로 만든다
#   E2E_SIGNUP_CODE   비밀번호 가입 코드(기본 e2e-signup-code)
#   SKIP_BUILD=1      빌드를 건너뜀(이미 server/build/install 이 있을 때)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${E2E_PORT:-18080}"
PG_HOST="${PG_HOST:-localhost}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-fitlog}"
PG_PASSWORD="${PG_PASSWORD:-fitlog}"
E2E_DB="${E2E_DB:-fitlog_e2e}"
SIGNUP_CODE="${E2E_SIGNUP_CODE:-e2e-signup-code}"
LOG="$ROOT/e2e/.server.log"
STATE="$ROOT/e2e/.state.json"
BASE="http://localhost:$PORT"
SERVER_PID=""

export PGPASSWORD="$PG_PASSWORD"

log() { echo "[run_local] $*"; }

stop_server() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    # 정상 종료(SIGTERM)를 기다리고, 안 끝나면 강제 종료
    for _ in $(seq 1 40); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.5; done
    kill -9 "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  SERVER_PID=""
}
trap stop_server EXIT

start_server() {
  # 운영(render.yaml)과 같은 설정: 비밀번호 로그인, 프록시 신뢰, 공개 주소.
  # 호출 제한은 테스트가 빨리 돌도록 크게 올린다
  DATABASE_URL="postgres://$PG_USER:$PG_PASSWORD@$PG_HOST:$PG_PORT/$E2E_DB" \
  JWT_SECRET="e2e-jwt-secret-e2e-jwt-secret-0123456789" \
  PASSWORD_LOGIN_ENABLED=true \
  PASSWORD_SIGNUP_CODE="$SIGNUP_CODE" \
  PUBLIC_BASE_URL="$BASE" \
  TRUST_PROXY=true \
  PORT="$PORT" \
  RATE_LIMIT_AUTH_PER_MIN=2000 RATE_LIMIT_API_PER_MIN=20000 RATE_LIMIT_EXPORT_PER_10MIN=1000 RATE_LIMIT_MCP_PER_MIN=20000 \
  JAVA_OPTS="${JAVA_OPTS:--Xmx512m}" \
  "$ROOT"/server/build/install/*/bin/fitlog-server >>"$LOG" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 120); do
    if curl -fsS "$BASE/health/ready" >/dev/null 2>&1; then log "서버 준비됨 (pid $SERVER_PID)"; return 0; fi
    kill -0 "$SERVER_PID" 2>/dev/null || { log "서버가 시작 직후 종료됨"; return 1; }
    sleep 1
  done
  log "서버가 120초 안에 준비되지 않음"; return 1
}

fail() {
  log "실패: $*"
  echo "----- 서버 로그 마지막 80줄 ($LOG) -----"
  tail -n 80 "$LOG" 2>/dev/null || true
  exit 1
}

: >"$LOG"
rm -f "$STATE"

# 다른 서버가 같은 포트를 쓰고 있으면 엉뚱한 서버를 점검하게 되므로 바로 중단한다
if curl -sS -o /dev/null --max-time 2 "$BASE/health/ready" 2>/dev/null; then
  fail "포트 $PORT 에 이미 서버가 떠 있음. E2E_PORT 를 바꾸거나 그 서버를 먼저 종료하세요"
fi

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  log "서버 빌드 (gradlew installDist)"
  ok=0
  for i in 1 2 3; do
    if (cd "$ROOT/server" && ./gradlew installDist --no-daemon -q); then ok=1; break; fi
    log "빌드 실패(Maven Central 429 등일 수 있음). 20초 뒤 재시도 $i/3"; sleep 20
  done
  [[ $ok == 1 ]] || fail "빌드 실패"
fi

log "DB $E2E_DB 새로 만들기"
psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -v ON_ERROR_STOP=1 -q \
  -c "DROP DATABASE IF EXISTS \"$E2E_DB\" WITH (FORCE)" -c "CREATE DATABASE \"$E2E_DB\"" || fail "DB 준비 실패"

log "1) 서버 시작"
start_server || fail "서버 시작 실패"

log "2) 재시작 전 점검"
python3 "$ROOT/e2e/run.py" --base-url "$BASE" --public-base-url "$BASE" --phase before-restart \
  --signup-code "$SIGNUP_CODE" --state "$STATE"
RC1=$?

log "3) 서버 종료 후 재시작 (같은 DB·JWT_SECRET)"
stop_server
echo "=== 서버 재시작 ===" >>"$LOG"
start_server || fail "서버 재시작 실패"

log "4) 재시작 후 점검"
python3 "$ROOT/e2e/run.py" --base-url "$BASE" --public-base-url "$BASE" --phase after-restart --state "$STATE"
RC2=$?

stop_server
if [[ $RC1 -ne 0 || $RC2 -ne 0 ]]; then
  fail "E2E 점검 실패 (재시작 전 종료코드 $RC1, 재시작 후 $RC2)"
fi
log "모든 E2E 점검 통과"
