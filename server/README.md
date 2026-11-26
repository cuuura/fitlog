# fitlog server

Kotlin 2.1 · Ktor 3.1 · Exposed 0.61 · Flyway · PostgreSQL 16 · JDK 21. 계약은 `../contracts/v0.1/`.

## 실행
```bash
export DB_URL=jdbc:postgresql://localhost:5432/fitlog DB_USER=fitlog DB_PASSWORD=fitlog
export JWT_SECRET=<32자 이상 임의 문자열>
export GOOGLE_CLIENT_IDS=<Android/Web OAuth 클라이언트 ID, 쉼표 구분>
./gradlew run        # :8080, 시작 시 Flyway 마이그레이션
```

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

## 동기화 구현 규칙
- 동기화 대상 테이블 쓰기 전 `lockUser(userId)` → 같은 사용자의 `server_seq` 가 커밋 순서대로 매겨져 pull 이 변경을 놓치지 않는다
- push 로 적용된 행의 `updated_at` = `clientUpdatedAt`. 서버 `updated_at` 이 더 최신일 때만 conflict
