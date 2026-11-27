# v1.0 보완 — 아이디·비밀번호 로그인 (테스트용)

테스트 기간에 Google 로그인 없이 쓰기 위한 로그인이다. 서버 설정으로 켜고 끄며 **기본은 꺼짐**. 기존 Google 로그인·토큰 형식은 그대로다.

## 서버 설정
| 환경 변수 | 기본 | 뜻 |
| --- | --- | --- |
| `PASSWORD_LOGIN_ENABLED` | `false` | `true`면 아래 경로가 열린다. `false`면 `/v1/auth/password/*`가 404 |
| `PASSWORD_SIGNUP_CODE` | 없음 | 가입 코드. 없으면 가입은 막히고(403) 로그인만 된다 |

## API (인증 없음, `/v1/auth/*` 호출 제한 버킷)

### `GET /v1/auth/methods`
항상 200. 앱이 로그인 화면에 무엇을 보여줄지 정한다.
```json
{ "google": true, "password": false, "passwordSignup": false }
```
- `password` = `PASSWORD_LOGIN_ENABLED`, `passwordSignup` = 로그인이 켜져 있고 가입 코드가 설정됨

### `POST /v1/auth/password/register`
```json
{ "username": "jaesung", "password": "8자 이상", "signupCode": "…", "displayName": "선택" }
```
- 200 `AuthTokens`(v0.1 `/v1/auth/google`과 같은 형식, `isNewUser: true`)
- `username`: 앞뒤 공백 제거 후 소문자로 저장. 3~32자, `[a-z0-9._-]`. 비밀번호: 8~128자
- 400 `VALIDATION_FAILED`(field: `username`|`password`), 403 `FORBIDDEN`(가입 코드 틀림 또는 가입 꺼짐), 409 `CONFLICT`(이미 있는 아이디)

### `POST /v1/auth/password/login`
```json
{ "username": "jaesung", "password": "…" }
```
- 200 `AuthTokens`(`isNewUser: false`)
- 401 `UNAUTHENTICATED` "invalid username or password"(아이디 없음·비밀번호 틀림 구분 안 함)
- 같은 아이디로 5번 연속 실패하면 15분 잠금: 429 `RATE_LIMITED` + `Retry-After`. 성공하면 실패 횟수 초기화

이후 토큰 갱신·로그아웃·계정 삭제는 기존 경로 그대로다.

## Play Integrity
`register`·`login`에도 `X-Integrity-Token`을 붙일 수 있다. `requestHash` = 정규화 전 입력 `username` 문자열의 SHA-256 base64url(패딩 없음). 서버 모드 규칙은 `security.md`와 같다.

## 알아둘 점
- 비밀번호 계정의 `/v1/me` `email`은 `<username>@password.local`로 보인다. 앱은 비밀번호 계정이면 이메일 대신 아이디를 보여줘도 된다(`email`이 `@password.local`로 끝남)
- AI 연동(MCP) 동의 화면은 Google 로그인과 아이디·비밀번호 로그인을 모두 지원한다(PASSWORD_LOGIN_ENABLED 일 때). e2e/run.py 가 비밀번호 계정으로 전체 OAuth 흐름을 점검한다
- 운영(스토어 출시) 전에는 `PASSWORD_LOGIN_ENABLED=false`로 끈다
