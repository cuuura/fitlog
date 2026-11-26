# v0.2 계약 — 프로그램 엔진

v0.1 계약(`../v0.1/`)에 **더하는** 계약이다. v0.1 내용은 여기서 바꾼다고 적은 곳만 바뀐다. WP는 이 계약을 바꾸지 않는다. 바꿔야 하면 트랙 리드에게 올린다.

| 파일 | 내용 | 주 사용자 |
| --- | --- | --- |
| `program.schema.json` | 프로그램 정의 JSON 스키마(JSON Schema 2020-12). AI·사용자·템플릿이 모두 이 형식 | A1(소유), A2, B1 |
| `engine.md` | 계산 엔진 규칙: 무게 결정, 성공·실패, 증량·디로드, 반올림, 일정·건너뛰기, 재계산 | A2(소유), A3 |
| `templates/` | 기본 템플릿 예시 2종(5x5, nSuns 4일). A1이 나머지 3종을 같은 형식으로 작성 | A1, A2 테스트 |
| `openapi.yaml` | v0.2에서 **추가·변경되는** API만 | A3, B1~B3 |
| `db/V3__programs.sql` | DB 변경(프로그램, 진행 상태, 세션 연결, 1RM 측정, v0.1 보완) | A3(소유) |
| `sync.md` | v0.1 동기화 규칙에 더해지는 부분 | A3, B3 |

## WP와 소유 디렉터리

| WP | 소유 | 범위(기능 ID) | 완료 기준 |
| --- | --- | --- | --- |
| A1 스키마·템플릿 | `server/.../program/schema/`, `server/src/main/resources/programs/` | PRG-1, PRG-2(JSON) | 스키마 검증기(에러 경로 포함), 템플릿 5종(StrongLifts 5x5, nSuns 5/3/1 LP 4일, 5/3/1 BBB, GZCLP, Texas Method)이 검증 통과 |
| A2 계산 엔진 | `server/.../engine/` (DB·HTTP 의존 없음, 순수 Kotlin) | PRG-3, PRG-11, PRG-12, PRG-14 | `engine.md`의 테스트 벡터 전부 통과, 5x5·nSuns 4주 시뮬레이션이 원래 규칙과 일치 |
| A3 진행·통계 API | `server/.../program/`(schema 제외), `.../records/`, `db/migration/V3` | PRG-5, PRG-6, PRG-8, PRG-13, LOG-10, STA-1~3, STA-6 + v0.1 보완 | `openapi.yaml`의 모든 경로 통합 테스트 통과 |
| B1 프로그램 시작 | `app/lib/features/programs/` | PRG-1, PRG-6, PRG-13, PRG-14 | 템플릿 목록·상세, 초기 TM 제안·입력, 여러 프로그램 목록·일시정지·재개, 건너뛰기 방식 선택 |
| B2 오늘 세션 | `app/lib/features/session/`(v0.1 B2 소유 그대로), `app/lib/data/plan_cache/` | PRG-5, PRG-8, LOG-3, LOG-9(일부), LOG-11 | 계획 세트 미리 채움, 지난 같은 세션 표시, 무게 수정(그 회차만), 세트 추가·삭제·순서 변경, 보조운동 추가, 세션 요약에 다음 회차 무게, 오프라인 시 캐시된 계획 사용 |
| B3 히스토리·PR + v0.1 보완 | `app/lib/features/history/`, `.../records/`, `app/lib/data/sync/`(동기화 상태), 설정 null 처리 | STA-1~3, STA-6, LOG-10 + 보완 | 세션 목록·상세·수정, PR·1RM 화면, 1RM 측정 입력, 추정식 설정, 동기화 상태 화면, 키·성별 비우기 |

공통 골격(새 DTO·API 클라이언트 메서드, 저장소 인터페이스, 라우트)은 트랙 리드가 WP 시작 전에 만든다.

## v0.1에서 넘어온 일 (v0.2에서 처리)

| 항목 | 담당 | 계약 반영 |
| --- | --- | --- |
| `session_exercise.exercise_id` FK에 ON DELETE CASCADE | A3 | `db/V3__programs.sql` |
| `POST /v1/exercises` 409·재전송 201, push `SERVER_ERROR` 코드 명시 | A3 | `openapi.yaml` |
| 설정에서 값 비우기: PUT `/v1/me/settings`에서 **필드가 null이면 비움, 필드가 없으면 그대로** | A3, B3 | `openapi.yaml` |
| 동기화 상태 화면 | B3 | 앱만 |
| 실기기 확인(Google 로그인, 휴식 알림, APK, 오프라인 동기화) | 사용자 폰 | 클라우드에 Android SDK가 없어 리드가 확인 절차를 `app/README.md`에 적고 사용자 확인을 요청 |

## v0.2 완료 기준

1. 5x5와 nSuns 4일로 4주치를 시뮬레이션했을 때 다음 회차 무게가 원래 규칙과 일치한다(A2 단위 테스트).
2. 앱에서 템플릿을 골라 초기 TM을 넣고 시작하면, 오늘 세션이 계획 무게로 미리 채워진다.
3. 세션을 끝내면 다음 회차 무게가 규칙대로 바뀌고, 지난 세션을 고치면 이후 계획이 다시 계산된다.
4. 두 프로그램을 동시에 진행해도 서로의 TM·주차가 섞이지 않는다.
