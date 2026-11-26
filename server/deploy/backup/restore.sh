#!/usr/bin/env bash
# 백업 복구: restore.sh <덤프 파일> [대상 DB 이름]
# 대상 DB 가 이미 있으면 내용을 덮어쓴다(--clean --if-exists). 없으면 만든다.
# 운영 DB 를 덮어쓰기 전에 서버를 멈추고(docker compose stop server), YES=1 로 확인을 건너뛸 수 있다.
# 접속 정보는 libpq 환경 변수(PGHOST PGPORT PGUSER PGPASSWORD).
set -Eeuo pipefail

FILE="${1:-}"
TARGET="${2:-${PGDATABASE:-fitlog}}"
[ -n "$FILE" ] && [ -f "$FILE" ] || { echo "usage: $0 <dump file> [target db]" >&2; exit 2; }

if [ "${YES:-0}" != "1" ]; then
  read -r -p "'$FILE' 을(를) DB '$TARGET' 에 복구합니다. 기존 데이터가 덮어써집니다. 계속? [y/N] " ans
  [ "$ans" = "y" ] || { echo "취소"; exit 1; }
fi

exists=$(psql -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$TARGET'")
if [ -z "$exists" ]; then
  echo "creating database $TARGET"
  createdb "$TARGET"
fi

# 서버 시작 시 Flyway 가 스키마 이력을 확인하므로 flyway_schema_history 도 함께 복구된다
pg_restore --clean --if-exists --no-owner --exit-on-error -d "$TARGET" "$FILE"
echo "restored $FILE -> $TARGET"
