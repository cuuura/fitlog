# v1.0 보안 — Play Integrity와 호출 제한

## Play Integrity

### 앱
- 표준 요청(Standard API). 앱 시작 시 `prepareIntegrityToken(cloudProjectNumber)`로 토큰 제공자를 준비하고, 인증 요청 직전에 `request(requestHash)`로 토큰을 얻는다
- `requestHash` = 요청 본문의 토큰 값(`/v1/auth/google`이면 `idToken`, `/v1/auth/refresh`이면 `refreshToken`)을 UTF-8로 SHA-256 한 값의 base64url(패딩 없음)
- 헤더: `X-Integrity-Token: <토큰>`. 토큰을 못 얻으면(Play 서비스 없음, 오류, 2초 초과, 클라우드 프로젝트 번호 미설정) 헤더 없이 보낸다
- 클라우드 프로젝트 번호는 빌드 시 `--dart-define=PLAY_CLOUD_PROJECT_NUMBER=<숫자>`. 없으면 무결성 기능 꺼짐
- Android 외 플랫폼(웹·테스트)은 헤더를 붙이지 않는다

### 서버
- 환경 변수 `INTEGRITY_MODE` = `off`(기본, 헤더 무시) | `report`(검증·로그만, 막지 않음) | `enforce`
- `enforce`에서 헤더 없음·검증 실패 모두 `403 INTEGRITY_FAILED`
- 검증: Google `decodeIntegrityToken`(서비스 계정). 확인 항목: `requestDetails.requestHash` 일치, `appIntegrity.appRecognitionVerdict = PLAY_RECOGNIZED`, 패키지 이름, `deviceIntegrity`에 `MEETS_DEVICE_INTEGRITY`
- 적용 경로: `POST /v1/auth/google`, `POST /v1/auth/refresh`만. `/oauth/*`(MCP 동의 웹 페이지)는 브라우저라 제외

## 호출 제한

| 범위 | 기준 | 기본 한도 |
| --- | --- | --- |
| `/v1/auth/*`, `/oauth/*` | IP | 분당 20 |
| 인증된 `/v1/*` | 사용자 | 분당 300 |
| `/v1/export.*` | 사용자 | 10분에 5 |
| `/mcp` | 사용자 | 분당 120 |

- 숫자는 서버 환경 변수로 바꿀 수 있다
- 초과 시 `429` + `Retry-After: <초>` 헤더 + 기존 에러 형식 `{ "error": { "code": "RATE_LIMITED", "message": … } }`

### 앱 처리
- 일반 요청: `RATE_LIMITED`면 "잠시 후 다시 시도" 안내(재시도 버튼). 자동 재시도는 하지 않는다
- 동기화: 429면 `Retry-After`(없으면 30초)만큼 미루고 다시 시도. 그동안 기록은 로컬에 쌓인다
- 토큰 갱신이 429면 로그아웃하지 않고 다음 요청 때 다시 시도

## 서버 보완 (서버 트랙, 앱 동작에는 영향 없음)
- 검증 항목 추가: `requestDetails.requestPackageName`·`appIntegrity.packageName`이 허용 목록(`INTEGRITY_PACKAGE_NAMES`, 기본 `com.fitlog.fitlog`)에 있음, `requestDetails.timestampMillis`가 10분 이내
- Google 호출 자체가 실패하면(네트워크·5xx·시간 초과 3초) `enforce`에서도 막지 않고 경고 로그만 남긴다(fail-open). 판정이 나쁜 경우와 헤더가 없는 경우만 403
- 호출 제한 `/v1/auth/*`·`/oauth/*` 버킷은 `/.well-known/*`도 포함한다. IP는 `TRUST_PROXY=true`일 때만 `X-Forwarded-For`를 쓴다
- 호출 제한 끄기: `RATE_LIMIT_ENABLED=false`. 한도: `RATE_LIMIT_AUTH_PER_MIN`, `RATE_LIMIT_API_PER_MIN`, `RATE_LIMIT_EXPORT_PER_10MIN`, `RATE_LIMIT_MCP_PER_MIN`
- 기존 MCP 도구 호출 제한(토큰당 분당 60, 쓰기 20, JSON-RPC 오류 응답)은 그대로 남는다
