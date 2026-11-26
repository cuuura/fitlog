#!/usr/bin/env bash
# 복구 리허설: 백업을 임시 DB 에 복구해 원본과 테이블별 행 수를 비교한 뒤 임시 DB 를 지운다.
#   restore-check.sh                 지금 DB 를 새로 덤프해서 검사 (백업 파일 + 복구 과정 전체 확인)
#   restore-check.sh <덤프 파일>     기존 백업 파일을 원본 DB 와 비교 (그 사이 바뀐 행은 차이로 보일 수 있음)
# 접속 정보는 libpq 환경 변수(PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE). CREATEDB 권한 필요.
# 다르면 0 이 아닌 코드로 끝난다. 정기 점검은 월 1회 권장.
set -Eeuo pipefail

SRC="${PGDATABASE:-fitlog}"
TMPDB="fitlog_restore_check_$$"
WORK="$(mktemp -d)"
FILE="${1:-}"

cleanup() {
  rm -rf "$WORK"
  dropdb --if-exists "$TMPDB" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [ -z "$FILE" ]; then
  FILE="$WORK/check.dump"
  echo "dumping $SRC -> $FILE"
  pg_dump -Fc --no-owner -f "$FILE" "$SRC"
fi
[ -f "$FILE" ] || { echo "no such file: $FILE" >&2; exit 2; }

echo "restoring into temp db $TMPDB"
createdb "$TMPDB"
pg_restore --no-owner --exit-on-error -d "$TMPDB" "$FILE"

# public 스키마의 모든 테이블 행 수 (정렬된 "테이블 행수" 목록)
count_rows() {
  local db="$1" t
  for t in $(psql -d "$db" -Atc "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename"); do
    echo "$t $(psql -d "$db" -Atc "SELECT count(*) FROM \"$t\"")"
  done
}
count_rows "$SRC" | LC_ALL=C sort > "$WORK/src.txt"
count_rows "$TMPDB" | LC_ALL=C sort > "$WORK/restored.txt"

printf '%-34s %12s %12s\n' TABLE SOURCE RESTORED
LC_ALL=C join "$WORK/src.txt" "$WORK/restored.txt" | awk '{printf "%-34s %12s %12s%s\n", $1, $2, $3, ($2==$3 ? "" : "  <-- DIFF")}'

if diff -q "$WORK/src.txt" "$WORK/restored.txt" >/dev/null; then
  echo "RESTORE CHECK OK ($(wc -l < "$WORK/src.txt") tables)"
else
  echo "RESTORE CHECK FAILED: row counts differ" >&2
  exit 1
fi
