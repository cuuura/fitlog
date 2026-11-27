# 라이브 계약 테스트 (`app/test_live`)

실제로 떠 있는 서버를 상대로, 앱이 쓰는 **진짜** API 계층을 돌리는 테스트입니다.
가짜 서버·목이 없습니다. 앱의 `createApiDio`(콜드 스타트 재시도), `AuthInterceptor`(401 → refresh),
`ApiClient`, 모든 DTO, drift 저장소(메모리 DB)와 `SyncEngine`, 인증 컨트롤러를 그대로 씁니다.
응답이 앱 DTO로 파싱되지 않거나 앱이 보내는 요청을 서버가 거절하면 실패합니다
(예: 동의 버전 불일치, enum 값 누락, 로그아웃에 Bearer 누락, sync pull 에 출처 필드 누락).

`flutter test`(기본, `test/` 폴더)에는 포함되지 않습니다. `FITLOG_LIVE_BASE_URL`이 없으면 전부 건너뜁니다.

## 흐름 (한 계정, 위에서 아래로)

가입 → 동의(`AppConfig.consentVersion`) → 설정 → 종목 목록·내 종목(outbox → push) → 프로그램 템플릿 전부 파싱
→ 인스턴스 시작·plan·PATCH·보조운동 → 프로그램 회차로 세션 기록(102.5kg, drift + sync push)
→ 다른 기기(빈 DB) sync pull → records·1RM·progress·comparison → 체중(push/pull)
→ AI 가져오기(preview/저장/충돌 409/되돌리기, pull 로 받은 행의 출처) → 삭제 요청·AI 연결·MCP 안내·내보내기
→ 로그아웃(리프레시 토큰 폐기 확인) → 재로그인 → 계정 삭제.

## 환경변수

| 이름 | 설명 |
| --- | --- |
| `FITLOG_LIVE_BASE_URL` | 서버 주소(끝 슬래시 없이). 없으면 전부 skip |
| `FITLOG_LIVE_SIGNUP_CODE` | 서버의 `PASSWORD_SIGNUP_CODE` 와 같은 값 |

서버는 아이디·비밀번호 로그인이 켜져 있어야 합니다(`PASSWORD_LOGIN_ENABLED=true`, `PASSWORD_SIGNUP_CODE`).
호출 제한은 끄는 것을 권장합니다(`RATE_LIMIT_ENABLED=false`): 테스트가 짧은 시간에 요청을 많이 보냅니다.
테스트가 만든 계정은 마지막에 `DELETE /v1/me`로 지웁니다.

## 로컬에서 실행

```bash
# 1) PostgreSQL(localhost:5432, 사용자/비밀번호 fitlog/fitlog)에 빈 DB 만들기
createdb -h localhost -U fitlog fitlog_it     # 또는 psql 로 CREATE DATABASE fitlog_it;

# 2) 서버 빌드·실행 (Java 21)
cd server
./gradlew installDist
DATABASE_URL=postgres://fitlog:fitlog@localhost:5432/fitlog_it \
JWT_SECRET=test-secret-test-secret-test-secret-1234 \
PASSWORD_LOGIN_ENABLED=true PASSWORD_SIGNUP_CODE=e2e-code \
RATE_LIMIT_ENABLED=false PORT=8091 \
build/install/*/bin/fitlog-server &
until curl -sf localhost:8091/health; do sleep 1; done

# 3) 테스트
cd ../app
flutter pub get
FITLOG_LIVE_BASE_URL=http://localhost:8091 FITLOG_LIVE_SIGNUP_CODE=e2e-code flutter test test_live
```

`FITLOG_LIVE_BASE_URL`을 배포된 서버로 바꾸면 그 서버로도 돌릴 수 있습니다(가입 코드가 필요).
무료 호스팅이 잠들어 있으면 첫 요청이 최대 1분 걸립니다(앱과 같은 재시도·타임아웃이 적용됩니다).

## CI 에서

```bash
cd app && FITLOG_LIVE_BASE_URL=http://localhost:8091 FITLOG_LIVE_SIGNUP_CODE=e2e-code flutter test test_live
```

워크플로는 PostgreSQL 서비스, 위 2)의 서버 실행(백그라운드), `/health` 대기, 그다음 이 명령 순서면 됩니다.
