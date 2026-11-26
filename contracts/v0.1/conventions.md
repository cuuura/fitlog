# 공통 규칙

## 스택
- 서버: Kotlin 2.x, Ktor 3, DB 접근 Exposed, 마이그레이션 Flyway, PostgreSQL 16, JDK 21
- 앱: Flutter 3.x (Dart 3), 상태 관리 Riverpod, 로컬 DB **drift**(SQLite), HTTP dio, 라우팅 go_router
- API 클라이언트: `openapi.yaml`에서 생성하지 않고 손으로 작성하되 DTO 이름은 스키마 이름과 같게 한다

## ID
- 모든 엔티티 ID는 **클라이언트가 만드는 UUIDv7** 문자열이다. 서버도 같은 형식으로 만든다
- 오프라인에서 만든 레코드도 처음 만든 ID를 끝까지 쓴다(동기화 시 ID 변환 없음)

## 시간
- 모든 시각은 ISO-8601 UTC(`2026-11-26T10:00:00Z`)로 주고받는다
- 세션은 `startedAt`과 함께 사용자 시간대 `tz`(IANA, 예: `Asia/Seoul`)를 저장한다. 세션의 "날짜"는 `startedAt`을 `tz`로 바꾼 날짜다(자정을 넘겨도 시작한 날)

## 단위
- 무게는 항상 **kg, 소수점 둘째 자리까지**(`numeric(6,2)`) 저장·전송한다. lb 표시는 앱에서만 변환
- 거리는 m, 시간은 초(정수)
- 덤벨은 **한쪽 무게**를 저장하고 `loadMode = PER_SIDE`로 표시한다

## 기록 유형 (`ExerciseType`)
| 값 | 필수 필드 | 예 |
| --- | --- | --- |
| `BARBELL` | weightKg, reps | 스쿼트 |
| `DUMBBELL` | weightKg(한쪽), reps | 덤벨 프레스 |
| `MACHINE` | weightKg, reps | 레그 프레스 |
| `BODYWEIGHT` | reps, addedWeightKg(선택, 음수=보조) | 풀업 |
| `BAND` | reps, bandLevel(선택) | v1.1 |
| `CARDIO` | durationSec, distanceM(선택) | v1.1 |

v0.1에서는 앞의 4개만 화면에 제공한다. 서버와 DB는 6개를 모두 받는다.

## 에러 형식
```json
{ "error": { "code": "VALIDATION_FAILED", "message": "reps must be >= 0", "field": "sets[2].reps" } }
```
- 400 VALIDATION_FAILED, 401 UNAUTHENTICATED, 403 FORBIDDEN, 404 NOT_FOUND, 409 CONFLICT, 429 RATE_LIMITED

## 인증
- 앱은 Google Sign-In으로 받은 ID 토큰을 `POST /v1/auth/google`에 보낸다
- 서버는 액세스 토큰(JWT, 15분)과 리프레시 토큰(불투명 문자열, 30일, 회전)을 준다
- 모든 API는 `Authorization: Bearer <access>`

## 삭제
- 사용자 데이터 삭제는 소프트 삭제(`deletedAt`)로 하고 동기화로 전파한다
- 계정 삭제는 하드 삭제(모든 행 즉시 삭제)

## 계산 로직
- v0.1에는 계산 엔진이 없다. 이후 버전에서도 계산은 서버 엔진 모듈에서만 한다
