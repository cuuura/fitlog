# v0.1 계약 (Contracts)

v0.1 병렬 작업(서버 A1~A3, 앱 B1~B3)이 공유하는 계약이다. WP는 이 계약을 바꾸지 않는다. 바꿔야 하면 트랙 리드에게 올린다.

| 파일 | 내용 | 주 사용자 |
| --- | --- | --- |
| `openapi.yaml` | REST API 명세 (OpenAPI 3.1) | A1, A3, B1~B3 |
| `db/V1__init.sql` | PostgreSQL 초기 스키마 (Flyway) | A2 (소유), A1·A3 (사용) |
| `sync.md` | 오프라인 기록·동기화 규칙 | A3, B3 |
| `conventions.md` | 공통 규칙(ID, 시간, 단위, 에러, 폴더 소유) | 전원 |

## WP와 소유 디렉터리

| WP | 소유 디렉터리 | 기능 ID |
| --- | --- | --- |
| A1 인증·계정 | `server/src/main/kotlin/.../auth/`, `.../account/` | ACC-1, ACC-5, ACC-6 |
| A2 데이터 모델·종목 | `server/src/main/resources/db/`, `.../exercise/`, 시드 데이터 | EXR-1, EXR-2 |
| A3 기록 API·동기화 | `.../session/`, `.../body/`, `.../sync/` | LOG-1, LOG-2, LOG-8, BDY-1, BDY-5 |
| B1 앱 골격·계정 | `app/lib/core/`, `app/lib/features/auth/`, `.../settings/`, `.../profile/` | ACC-1, ACC-3, ACC-5, ACC-6, BDY-1, BDY-5 |
| B2 세션 기록 화면 | `app/lib/features/session/`, `.../exercise_picker/` | LOG-1, LOG-2, LOG-5(일부), LOG-7 |
| B3 타이머·오프라인 | `app/lib/features/rest_timer/`, `app/lib/data/local/`, `app/lib/data/sync/` | LOG-4, LOG-8, LOG-12(일부) |

공통 골격(서버 Gradle 프로젝트, 앱 Flutter 프로젝트, API 클라이언트 생성)은 트랙 리드가 WP 시작 전에 만든다.

## v0.1 완료 기준

로그인 후 프로그램 없이 세션을 시작해 세트를 기록하고, 오프라인에서 기록한 뒤 연결하면 서버에 남는다.
