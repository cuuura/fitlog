#!/usr/bin/env bash
# fitlog DB 백업: pg_dump -Fc → ${BACKUP_DIR}/fitlog-<UTC 날짜시각>.dump, 오래된 백업 삭제, 선택 업로드.
# 접속 정보는 libpq 환경 변수(PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE)로 받는다.
#   BACKUP_DIR             저장 폴더 (기본 /backups)
#   BACKUP_RETENTION_DAYS  보관 일수 (기본 30). 개인정보 처리방침의 백업 보관 기간과 같게 둔다
#   BACKUP_UPLOAD_CMD      선택. 성공 뒤 실행할 셸 명령. 환경 변수 BACKUP_FILE 에 방금 만든 파일 경로
#   ALERT_WEBHOOK_URL      선택. 실패 시 {"text": "..."} 를 POST
# 실패하면 로그를 남기고 0 이 아닌 코드로 끝난다.
set -Eeuo pipefail

BACKUP_DIR="${BACKUP_DIR:-/backups}"
RETENTION="${BACKUP_RETENTION_DAYS:-30}"
DB="${PGDATABASE:-fitlog}"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) backup: $*"; }

alert() {
  local msg="$1"
  [ -n "${ALERT_WEBHOOK_URL:-}" ] || return 0
  local payload
  payload=$(printf '{"text":"%s"}' "$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')")
  if command -v curl >/dev/null 2>&1; then
    curl -fsS -m 15 -H 'Content-Type: application/json' -d "$payload" "$ALERT_WEBHOOK_URL" >/dev/null \
      || log "WARN: alert webhook failed"
  else
    log "WARN: curl not found, alert webhook skipped"
  fi
}

TMP=""
on_error() {
  local code=$? line=$1
  [ -z "$TMP" ] || rm -f "$TMP"
  log "FAILED (exit $code, line $line)"
  alert "fitlog backup FAILED on $(hostname) db=$DB (exit $code, line $line)"
  exit "$code"
}
trap 'on_error $LINENO' ERR

mkdir -p "$BACKUP_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FILE="$BACKUP_DIR/fitlog-$STAMP.dump"
TMP="$FILE.partial"

log "start db=$DB -> $FILE"
pg_dump -Fc --no-owner -f "$TMP" "$DB"
# 덤프가 읽히는지 목차로 확인한 뒤 확정한다
pg_restore -l "$TMP" >/dev/null
mv "$TMP" "$FILE"
TMP=""
log "done size=$(du -h "$FILE" | cut -f1)"

# 보관 기간이 지난 백업 삭제 (미완성 .partial 도 하루 지나면 지운다)
find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'fitlog-*.dump' -o -name 'fitlog-*.dump.partial' \) \
  -mtime +"$RETENTION" -print -delete | sed 's/^/pruned: /' || true

if [ -n "${BACKUP_UPLOAD_CMD:-}" ]; then
  log "upload hook"
  BACKUP_FILE="$FILE" bash -c "$BACKUP_UPLOAD_CMD"
  log "upload done"
fi
