# fitlog 서버 운영 가이드 (v1.0)

배포는 Docker Compose(서버 + PostgreSQL 16 + 일일 백업, 선택 Caddy HTTPS)로 한다. 이미지는 GitHub Actions 가 `ghcr.io/<소유자>/fitlog-server` 로 올린다.

## 1. 구성

| 서비스 | 이미지 | 역할 |
| --- | --- | --- |
| `db` | `postgres:16` | 데이터. 볼륨 `pgdata` |
| `server` | `ghcr.io/cuuura/fitlog-server:${TAG}` | API·MCP·공개 페이지(:8080). 시작 시 Flyway 마이그레이션 |
| `backup` | `server/deploy/backup/Dockerfile` | 매일 03:00 UTC `pg_dump -Fc`, 오래된 백업 삭제 |
| `caddy` (프로필 `https`) | `caddy:2` | 자동 HTTPS 리버스 프록시 |

파일: 저장소 루트 `docker-compose.yml`, `server/Dockerfile`(빌드 컨텍스트는 **저장소 루트**), `server/deploy/{.env.example,Caddyfile,backup/,load/}`.

## 2. 처음 배포

```bash
git clone <저장소> && cd fitlog
cp server/deploy/.env.example .env      # 값을 채운다 (아래 3장)
docker compose pull server              # ghcr.io 에서 이미지 받기 (또는 아래 build)
docker compose up -d                     # 서버 + DB + 백업
curl -fsS http://localhost:8080/health/ready   # ok
```

- 직접 빌드: `docker compose up -d --build` (또는 `docker build -f server/Dockerfile -t fitlog-server .`)
- HTTPS(권장): 도메인 DNS 를 서버에 연결하고 80/443 을 연 뒤 `.env` 에 `DOMAIN=…`, `TRUST_PROXY=true`, `BIND_ADDR=127.0.0.1`, `PUBLIC_BASE_URL=https://…` 를 넣고 `docker compose --profile https up -d`
- ghcr.io 이미지가 비공개면 `echo <PAT(read:packages)> | docker login ghcr.io -u <사용자> --password-stdin` 먼저
- 처음 이미지를 올린 뒤 GitHub 패키지 설정에서 저장소와 연결·공개 범위를 정한다

## 3. 환경 변수

`server/deploy/.env.example` 에 전부 있다. 주요 항목:

| 변수 | 뜻 |
| --- | --- |
| `DB_USER` `DB_PASSWORD` `DB_NAME` | DB 계정. compose 가 `DB_URL` 을 만든다 |
| `JWT_SECRET` | **32자 이상 필수**(짧으면 시작 실패). 바꾸면 모든 로그인이 풀린다 |
| `GOOGLE_CLIENT_IDS` | 앱 로그인 ID 토큰 audience(쉼표 구분) |
| `PUBLIC_BASE_URL` | 외부 https 주소. MCP·OAuth·개인정보 처리방침 링크 |
| `GOOGLE_WEB_CLIENT_ID/SECRET` | AI 연동(MCP) 로그인 |
| `CONTACT_EMAIL` `POLICY_EFFECTIVE_DATE` `BACKUP_RETENTION_DAYS` | `/privacy`·`/account-deletion` 에 들어가는 값 |
| `INTEGRITY_MODE` `INTEGRITY_PACKAGE_NAMES` `PLAY_INTEGRITY_CREDENTIALS` | Play Integrity(off/report/enforce) |
| `RATE_LIMIT_*` `TRUST_PROXY` | 호출 제한. `TRUST_PROXY=true` 는 프록시 뒤에서만 |
| `MAX_BODY_BYTES` | 요청 본문 한도(기본 5MB). 초과 시 413 |
| `BACKUP_DIR` `BACKUP_HOUR_UTC` `BACKUP_UPLOAD_CMD` `ALERT_WEBHOOK_URL` | 백업 |

`BACKUP_RETENTION_DAYS` 는 개인정보 처리방침의 "삭제 후 최대 N일"과 같은 값이다. 바꾸면 방침 페이지도 같이 바뀐다.

## 4. 백업·복구

- 매일 `BACKUP_HOUR_UTC`(기본 03:00 UTC)에 `backup` 컨테이너가 `backups/fitlog-<UTC 날짜시각>.dump`(`pg_dump -Fc`)를 만들고, `BACKUP_RETENTION_DAYS`일 지난 파일을 지운다. 덤프는 만든 직후 `pg_restore -l` 로 읽히는지 확인한다.
- 지금 바로 백업: `docker compose exec backup /scripts/backup.sh`
- **원격 보관**(서버 디스크가 날아가는 경우 대비): `BACKUP_UPLOAD_CMD` 에 성공 뒤 실행할 명령을 적는다. 환경 변수 `BACKUP_FILE` 이 파일 경로다. 쓸 도구(rclone, aws cli 등)는 `server/deploy/backup/Dockerfile` 에 설치해야 한다. 가장 단순한 대안은 호스트의 cron 으로 `backups/` 폴더를 `rsync`·`rclone` 하는 것이다.
- **복구**:
  ```bash
  docker compose stop server
  docker compose exec -e YES=1 backup /scripts/restore.sh /backups/fitlog-20261201T030000Z.dump fitlog
  docker compose start server
  ```
  새 DB 로 먼저 확인하려면 마지막 인자를 `fitlog_check` 같은 다른 이름으로 준다.
- **복구 리허설(월 1회 권장)**: `docker compose exec backup /scripts/restore-check.sh` — 지금 DB 를 덤프해 임시 DB 에 복구하고 테이블별 행 수를 비교한 뒤 임시 DB 를 지운다. 달라지면 비정상 종료한다. 기존 백업 파일을 검사하려면 파일 경로를 인자로 준다(그 사이 변경분은 차이로 보일 수 있다).
- 호스트에서 직접 쓸 때(psql·pg_dump 설치됨): `PGHOST=… PGUSER=… PGPASSWORD=… PGDATABASE=fitlog ./server/deploy/backup/backup.sh`

## 5. 업그레이드

```bash
git pull
docker compose pull server && docker compose up -d server   # 새 이미지로 교체(TAG 로 고정 가능)
docker compose logs -f --tail=100 server
```

- 업그레이드 전에 `docker compose exec backup /scripts/backup.sh` 로 백업을 한 번 더 만든다.
- DB 스키마는 서버 시작 시 Flyway 가 올린다. 되돌릴 땐 이전 이미지 태그(`TAG=<sha>`) + 필요하면 백업 복구.
- 서버는 `SIGTERM` 을 받으면 진행 중 요청을 최대 10초 기다리고(최대 30초 안에 종료) DB 풀을 닫는다. compose `stop_grace_period` 는 40초.
- 이미지 태그: main 푸시 → `latest`·`sha-<짧은 해시>`, 태그 `server-vX.Y.Z` → `X.Y.Z`.

## 6. 모니터링

- **업타임**: 외부 모니터(UptimeRobot, Better Stack 등)로 `GET <PUBLIC_BASE_URL>/health/ready` 를 1분 간격 확인. 200 `ok` 이면 정상, DB 가 안 되면 503. 컨테이너는 같은 경로로 Docker `HEALTHCHECK` 를 한다(`docker compose ps` 의 health).
- **로그**: `docker compose logs server`. 모든 줄에 요청 ID 가 `[...]` 로 붙는다. 앱·사용자가 신고한 응답의 `X-Request-Id` 헤더로 해당 요청 로그를 찾는다. 요청이 `X-Request-Id`(영숫자·`._-`, 64자 이하)를 보내면 그 값을 쓰고, 없으면 서버가 만든다(Caddy 는 자동으로 붙인다).
- **백업 실패**: `backup.sh` 는 실패 시 로그(`backup: FAILED`)를 남기고 0 이 아닌 코드로 끝난다. `ALERT_WEBHOOK_URL` 을 설정하면 Slack·Discord 호환 `{"text": "..."}` 를 POST 한다. 그래도 놓치기 쉬우니 월 1회 `backups/` 에 최신 파일이 있는지 확인하고 복구 리허설을 돌린다.
- **디스크**: `docker system df`, `df -h` 로 DB 볼륨·백업 폴더 용량을 가끔 본다.

## 7. 부하 확인(선택)

[k6](https://k6.io) 스모크 스크립트: `server/deploy/load/k6-smoke.js`.

```bash
k6 run -e BASE_URL=https://fit.example.com -e ACCESS_TOKEN=<액세스 토큰> server/deploy/load/k6-smoke.js
```

토큰은 앱 로그인 후 얻은 액세스 토큰(15분 유효)을 쓴다. 호출 제한(사용자당 분당 300)에 걸리면 429 가 나오니, 부하를 올리려면 `RATE_LIMIT_API_PER_MIN` 을 임시로 키운다.

## 8. 보안 메모

- `.env` 는 커밋하지 않는다(`.gitignore` 에 있음). DB 포트는 외부에 열지 않는다(compose 에서 `db` 는 포트 공개 없음).
- 공개 페이지(`/privacy`, `/account-deletion`)는 CSP `default-src 'none'`, `nosniff`, `no-referrer` 헤더와 1시간 캐시로 나간다.
- 요청 본문은 `Content-Length` 가 `MAX_BODY_BYTES` 를 넘으면 읽지 않고 413 으로 거절한다.
