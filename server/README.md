# fitlog server

Kotlin 2.1 · Ktor 3.1 · Exposed 0.61 · Flyway · PostgreSQL 16 · JDK 21. 계약은 `../contracts/v0.1/`.

## 실행
```bash
export DB_URL=jdbc:postgresql://localhost:5432/fitlog DB_USER=fitlog DB_PASSWORD=fitlog
export JWT_SECRET=<32자 이상 임의 문자열>
export GOOGLE_CLIENT_IDS=<Android/Web OAuth 클라이언트 ID, 쉼표 구분>
./gradlew run        # :8080, 시작 시 Flyway 마이그레이션
```

## AI 연동(MCP) 실행 — v0.3
Claude·ChatGPT·Gemini 가 붙으려면 **https 공개 주소**가 필요하다. 자세한 절차는 [docs/mcp-connect.md](docs/mcp-connect.md).

1. PostgreSQL 16 준비(예: `docker run -d -p 5432:5432 -e POSTGRES_USER=fitlog -e POSTGRES_PASSWORD=fitlog -e POSTGRES_DB=fitlog postgres:16`)
2. 터널로 공개 주소 만들기: `cloudflared tunnel --url http://localhost:8080` (또는 `ngrok http 8080`) → `https://….trycloudflare.com`
3. Google Cloud 콘솔에서 **웹 애플리케이션** OAuth 클라이언트를 만들고 승인된 리디렉션 URI 에 `<공개 주소>/oauth/google/callback` 등록
4. 환경 변수와 실행
   ```bash
   export PUBLIC_BASE_URL=https://….trycloudflare.com      # 끝 슬래시 없음
   export GOOGLE_WEB_CLIENT_ID=… GOOGLE_WEB_CLIENT_SECRET=…
   export GOOGLE_CLIENT_IDS=<앱(Android) 클라이언트 ID>,<웹 클라이언트 ID>
   export JWT_SECRET=<32자 이상>
   ./gradlew run
   ```
5. 확인: `npx @modelcontextprotocol/inspector` → Streamable HTTP, `<공개 주소>/mcp` → OAuth 로그인 → 도구 22개
6. AI 연결: Claude(커넥터 추가) · ChatGPT(개발자 모드 커넥터) · Gemini CLI(`settings.json` 의 `mcpServers.<이름>.httpUrl`)에 `<공개 주소>/mcp`

| 환경 변수 | 뜻 |
| --- | --- |
| `PUBLIC_BASE_URL` | 외부에서 보이는 서버 주소. MCP 리소스·OAuth 메타데이터·리다이렉트에 쓴다 |
| `GOOGLE_WEB_CLIENT_ID` / `GOOGLE_WEB_CLIENT_SECRET` | MCP 로그인 페이지용 Google 웹 OAuth 클라이언트 |
| `GOOGLE_CLIENT_IDS` | 앱 로그인 ID 토큰 audience(쉼표 구분) |

### 호출 제한·무결성

| 환경 변수 | 기본 | 뜻 |
| --- | --- | --- |
| `RATE_LIMIT_ENABLED` | `true` | `false` 면 호출 제한을 설치하지 않는다 |
| `RATE_LIMIT_AUTH_PER_MIN` | 20 | `/v1/auth/*`·`/oauth/*` 분당 한도(IP별) |
| `RATE_LIMIT_API_PER_MIN` | 300 | 인증된 `/v1/*` 분당 한도(사용자별) |
| `RATE_LIMIT_EXPORT_PER_10MIN` | 5 | 내보내기 10분당 한도(사용자별) |
| `RATE_LIMIT_MCP_PER_MIN` | 120 | `/mcp` 분당 한도(Authorization 해시별, 없으면 IP) |
| `TRUST_PROXY` | `false` | `true` 일 때만 `X-Forwarded-For` 로 클라이언트 IP를 판단(리버스 프록시 뒤) |
| `INTEGRITY_MODE` | `off` | Play Integrity: `off` 무시 / `report` 검증·로그만 / `enforce` 실패 시 403 `INTEGRITY_FAILED` |
| `INTEGRITY_PACKAGE_NAMES` | `com.fitlog.fitlog` | 허용 패키지 이름(쉼표 구분). 첫 값으로 `decodeIntegrityToken` 호출 |
| `PLAY_INTEGRITY_CREDENTIALS` | - | 서비스 계정 JSON 파일 경로. Google 호출 실패(3초 초과 포함)는 fail-open(경고 로그) |

초과 시 `429` + `Retry-After`(초) + `{"error":{"code":"RATE_LIMITED",...}}`.

## Docker로 실행·배포 — v1.0
서버 + PostgreSQL 16 + 일일 백업을 Docker Compose 로 띄운다(저장소 루트 `docker-compose.yml`). 빌드 컨텍스트는 저장소 루트다(계약의 개인정보 처리방침 md 를 jar 에 묶는다).
```bash
cp server/deploy/.env.example .env     # JWT_SECRET(32자 이상), DB_PASSWORD, PUBLIC_BASE_URL, CONTACT_EMAIL 등 입력
docker compose up -d --build           # http://localhost:8080/health/ready → ok
docker compose --profile https up -d   # 선택: Caddy 자동 HTTPS (DOMAIN, TRUST_PROXY=true)
```
이미지는 main 푸시 때 GitHub Actions(`.github/workflows/server-image.yml`)가 `ghcr.io/<소유자>/fitlog-server` 로 올린다. 배포·백업·복구·모니터링은 [docs/ops.md](docs/ops.md), Play 스토어 등록은 [docs/play-store.md](docs/play-store.md).

Portainer 에서 GitHub 저장소 스택(빌드 없이 ghcr.io 이미지, Pull and redeploy)으로 배포하려면 `server/deploy/portainer/` 와 [docs/ops.md](docs/ops.md) 9장을 본다. 포트·리슨 주소·호스트 마운트 경로는 모두 환경 변수다.

공개 페이지: `/privacy`, `/account-deletion`, 준비 상태 `/health/ready`(DB 확인). 모든 응답에 `X-Request-Id`.

## 테스트
로컬 PostgreSQL 이 필요하다 (`fitlog_test` DB, 사용자/암호 `fitlog`). 다른 DB 는 `FITLOG_TEST_DB_URL` 로 지정.
```bash
./gradlew test
```
테스트 함수 이름은 영어로 쓴다(한글 백틱 이름은 일부 환경에서 클래스 파일 경로 오류).

## 구조
| 패키지 | 내용 |
| --- | --- |
| `core/` | 설정, DB(`dbQuery`), Exposed 테이블, 에러 형식, UUIDv7, JWT, `lockUser` |
| `auth/`, `account/` | Google 로그인, 토큰 회전, 내 정보·설정·동의·계정 삭제 |
| `exercise/` + `db/migration/V2` | 종목 API, 기본 종목 77개 시드(`db/SEED_EXERCISES.md`) |
| `session/`, `body/`, `sync/` | 세션·세트 기록, 체중, 오프라인 push/pull |
| `engine/` | v0.2 계산 엔진(순수 Kotlin): 증량·디로드·반올림·일정·replay |
| `program/schema`, `program/catalog`, `program/instance`, `records/` | 프로그램 검증·템플릿 5종·진행 인스턴스·PR/1RM |
| `importing/`, `mcp/`, `oauth/`, `export/`, `deletion/`, `aiconnection/` | v0.3 AI 가져오기·원격 MCP·OAuth·내보내기·삭제 승인·연결 관리 |
| `stats/`, `security/`, `ops/` | v1.0 그래프 집계(추이·회차 비교), 호출 제한·Play Integrity, 헬스·요청 ID·본문 제한·공개 페이지 |

## 동기화 구현 규칙
- 동기화 대상 테이블 쓰기 전 `lockUser(userId)` → 같은 사용자의 `server_seq` 가 커밋 순서대로 매겨져 pull 이 변경을 놓치지 않는다
- push 로 적용된 행의 `updated_at` = `clientUpdatedAt`. 서버 `updated_at` 이 더 최신일 때만 conflict
