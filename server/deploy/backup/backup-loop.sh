#!/usr/bin/env bash
# 백업 컨테이너 진입점: 매일 BACKUP_HOUR_UTC 시(기본 03:00 UTC)에 backup.sh 를 실행한다.
# 한 번 실패해도 루프는 계속 돌고, 실패는 backup.sh 가 로그·웹훅으로 알린다.
# BACKUP_ON_START=true 면 시작하자마자 한 번 실행한다.
set -u
HOUR="${BACKUP_HOUR_UTC:-3}"
DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "${BACKUP_ON_START:-false}" = "true" ]; then
  "$DIR/backup.sh" || true
fi

while true; do
  now=$(date -u +%s)
  next=$(date -u -d "today ${HOUR}:00" +%s)
  [ "$next" -gt "$now" ] || next=$(date -u -d "tomorrow ${HOUR}:00" +%s)
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) backup-loop: next run at $(date -u -d "@$next" +%Y-%m-%dT%H:%M:%SZ)"
  # 짧게 나눠 자야 SIGTERM 에 빨리 반응하고 시계 보정에도 강하다
  while [ "$(date -u +%s)" -lt "$next" ]; do sleep 30; done
  "$DIR/backup.sh" || true
done
