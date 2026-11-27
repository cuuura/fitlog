# 하루짜리 예정 운동 (LOG-13)

v0.1~v1.0 계약에 **더하는** 계약이다. 소유: 트랙 리드(Opus). WP는 바꾸지 않고, 바꿔야 하면 리드에게 올린다.

프로그램 없이 "이 날 이 운동을 이렇게 하겠다"는 계획 하나. AI(JSON·MCP)나 앱에서 만들고, 그날 앱에서 눌러 시작하면 목표가 채워진 세션이 열린다.

## 1. 결정 사항
- 엔티티 이름은 `scheduled_workout`(앱·서버 타입 `ScheduledWorkout`). v0.2 `PlannedWorkout`(프로그램 다음 회차)와 다른 것이다
- 종목·세트는 `items` JSON 하나에 담는다(별도 테이블 없음). 동기화·충돌은 문서 단위 last-write-wins
- **상태는 저장하지 않고 계산한다**
  - `DONE`: 이 예정을 가리키는(`workout_session.scheduled_workout_id`) 삭제되지 않은 세션이 있다(진행 중이어도 DONE이 아니라 `IN_PROGRESS`, `ended_at` 있으면 `DONE`)
  - `SKIPPED`: `skipped_at`이 있고 세션이 없다
  - `PLANNED`: 그 밖. 앱은 `plannedDate`가 오늘보다 앞이면 "지난 예정"으로 표시만 한다(자동 건너뛰기 없음)
- 예정일과 다른 날에도 시작할 수 있다. 예정 하나에 살아 있는 세션은 하나
- 하루에 예정 여러 개 허용. 프로그램 오늘 운동과 같은 날이어도 둘 다 보인다
- 예정 운동으로 한 세션은 **실패 판정을 하지 않는다**(프로그램 세션만 판정). PR·1RM·그래프에는 일반 세션처럼 들어간다. 프로그램 증량에는 영향 없음
- 삭제: 앱에서는 바로 삭제(소프트). AI는 `request_deletion`(앱 승인)만

## 2. 데이터 모양
```jsonc
// ScheduledWorkout (sync payload, REST 응답 공통. 날짜는 YYYY-MM-DD)
{
  "id": "uuid", "plannedDate": "2026-11-28", "title": "B-2 하체 2", "note": "RIR 3~4",
  "items": [                                  // 1~30개, 순서 = 운동 순서
    { "exerciseId": "uuid", "note": "벨트", "restSec": 180,   // restSec 0~3600, 선택
      "sets": [                               // 1~50개
        { "isWarmup": false, "targetWeightKg": 80, "targetReps": 12,
          "targetRepsMax": null, "targetRir": 3, "targetRpe": null, "targetDurationSec": null }
      ] }
  ],
  "skippedAt": null, "source": "AI_MCP", "importBatchId": "uuid|null",
  "updatedAt": "…", "deletedAt": null
}
```
- 세트 필드는 모두 선택. `targetRepsMax`가 있으면 `targetReps`도 있어야 하고 `targetRepsMax >= targetReps`(범위 "12~15")
- `targetRir` 0~10 정수, `targetRpe` 1~10(0.5 단위), `targetWeightKg >= 0`(DUMBBELL 한쪽 무게)
- `exerciseId`는 내 종목이나 기본 종목이어야 한다(서버 검증, 아니면 `rejected` `VALIDATION_FAILED`)
- REST·MCP 응답에는 계산 필드 `status: PLANNED|IN_PROGRESS|DONE|SKIPPED`, `sessionId`(있으면)를 더한다. sync payload에는 넣지 않는다

## 3. DB
`db/V6__scheduled_workout.sql`. 요약:
- `scheduled_workout` 테이블(위 필드 + `user_id`, `server_seq`, `created_at`)
- `workout_session.scheduled_workout_id`(FK ON DELETE SET NULL) + 부분 유니크(살아 있는 세션만)
- `workout_set.target_reps_max`, `target_rir`, `target_rest_sec`
- `import_item`·`deletion_request`의 entity CHECK에 `scheduled_workout` 추가

## 4. 동기화 (v0.1·v0.2 sync.md에 더함)
- 대상 엔티티에 `scheduled_workout` 추가. 앱은 부모 순서상 `exercise` 다음, `workout_session` 앞에 보낸다(entityRank)
- `workout_session` payload에 `scheduledWorkoutId` 추가. 그 예정이 아직 없으면 `rejected` `PARENT_MISSING`
- 같은 예정에 살아 있는 다른 세션이 이미 있으면 새 세션은 **연결을 끊고(`scheduledWorkoutId=null`) applied**(v0.2 중복 planSeq와 같은 방식). 응답 `server` 값으로 앱이 덮어쓴다
- `workout_set` payload에 `targetRepsMax`, `targetRir`, `targetRestSec` 추가
- 예정을 삭제해도 연결된 세션은 남는다(세션의 `scheduledWorkoutId`는 그대로, 앱은 없는 예정이면 무시)

## 5. 세션 시작 (앱)
예정 운동 "시작"은 로컬에서 세션을 만든다(오프라인 가능):
- `workout_session.scheduledWorkoutId = 예정 id`, `programInstanceId = null`, `note`는 비움, `source = APP`
- `items` 순서대로 `session_exercise`(note 복사), 세트마다 `workout_set`: `isWarmup`, `targetWeightKg`, `targetReps`, `targetRepsMax`, `targetRir`, `targetRestSec = item.restSec`. 기록값(weightKg·reps) 처리는 **기존 프로그램 회차 시작과 똑같이** 한다(지금 앱이 목표로 미리 채우면 채우고, 비우면 비운다), `completedAt = null`
- 휴식 타이머는 방금 끝낸 세트의 `targetRestSec`이 있으면 그 값, 없으면 설정 기본값
- 세트 표에 목표 "80kg × 12~15 · RIR 3"을 보여 준다. 실패(빨강) 표시는 하지 않는다

## 6. REST (openapi에 더함, 모두 인증 필요·남의 것 404)
| 메서드 | 경로 | 내용 |
| --- | --- | --- |
| GET | `/v1/scheduled-workouts?from=YYYY-MM-DD&to=YYYY-MM-DD` | 기간(포함) 예정 목록, 기본 오늘−7일~오늘+30일(사용자 tz), 최대 92일. `{ "items": [ScheduledWorkout + status + sessionId] }` |
| PUT | `/v1/scheduled-workouts/{id}` | 생성·전체 교체(본문 = §2, `updatedAt`·계산 필드 무시). 200 + 저장본 |
| DELETE | `/v1/scheduled-workouts/{id}` | 소프트 삭제 204 |
| POST | `/v1/scheduled-workouts/{id}/skip` | 본문 `{ "skipped": true|false }`. `skipped_at` 채우기·비우기. 200 + 저장본 |

앱은 평소 sync만 쓴다. REST는 웹·MCP·테스트용.

## 7. 가져오기 (import.schema.json·import.md에 더함)
- 묶음 최상위에 `scheduledWorkouts`(최대 30). 항목:
  `{ id?, plannedDate, title, note?, tz?, items: [{ exercise: {id}|{name}, note?, restSec?, sets: [set 목표 필드] }] }`
- 종목 이름 해석은 import.md §2 그대로(`UNKNOWN_EXERCISE` 충돌 등). `SKIP`한 종목은 그 item만 뺀다. item이 모두 빠지면 그 예정은 저장하지 않고 `SKIPPED`로 센다
- 새 충돌 `SCHEDULED_DUPLICATE`: 같은 `plannedDate`에 제목이 같은(공백·대소문자 무시) 살아 있는 예정이 있음. 해결 `SKIP`, `KEEP_BOTH`, `REPLACE`(기존 소프트 삭제 후 새로 저장). 필수
- `ID_EXISTS`도 적용된다
- `sessions[]` 항목에 선택 필드 `scheduledWorkoutId`(묶음 안 예정 id 또는 기존 예정 id). 없는 id면 연결 없이 저장
- `import_item.entity = 'scheduled_workout'`, `source`는 채널대로(AI_JSON·AI_MCP·IMPORT). 되돌리기는 그 예정을 소프트 삭제(연결 세션은 남음)
- 요약 `summary`의 카운트 키 `scheduledWorkouts`

## 8. 내보내기 (export.md에 더함)
- JSON에 `scheduledWorkouts`(삭제 제외, id 유지, 종목은 `{id}`)와 세션의 `scheduledWorkoutId`를 넣는다. 새 계정에 가져오면 같은 예정·연결이 된다. `skippedAt`은 가져오기 형식에 없으므로 내보내지 않는다(건너뜀 상태는 옮기지 않음)
- CSV는 바꾸지 않는다

## 9. MCP (mcp.md에 더함, 도구 22 → 25)
| 도구 | 범위 | 인자 | 동작 |
| --- | --- | --- | --- |
| `schedule_workout` | write | `workout`(§7 항목 하나), `resolutions?`, `onConflict?` | 묶음 `{scheduledWorkouts:[workout]}`로 가져오기. 결과에 저장된 예정(id·날짜·종목 수) |
| `list_scheduled_workouts` | read | `from?`, `to?`(YYYY-MM-DD), `status?` | REST GET과 같은 목록(status·sessionId 포함, 종목 이름 포함) |
| `skip_scheduled_workout` | write | `id`, `skipped?=true` | REST skip과 같음 |
- `request_deletion`의 `entity`에 `scheduled_workout` 추가
- 도구 설명에 안내: "앞으로 할 하루짜리 운동 계획은 `schedule_workout`, 이미 한 운동 기록은 `log_session`, 여러 주 반복 규칙은 `create_program`"
- 날짜 기본 tz는 사용자 최근 세션 tz, 없으면 Asia/Seoul

## 10. WP
| WP | 소유 | 범위 | 완료 기준 |
| --- | --- | --- | --- |
| SW-A 서버 저장·동기화 | `server/.../scheduled/`(새), V6, `core/Tables.kt` 추가분, sync·session·export·deletion 연결부 | §3 §4 §6 §8, 삭제 요청 실행 | 동기화 push/pull·중복 연결 끊기·PARENT_MISSING·REST 4개·내보내기 왕복 테스트 |
| SW-B 서버 가져오기·MCP | `server/.../importing/`, `server/.../mcp/` | §7 §9 | 이름 해석·SCHEDULED_DUPLICATE 3해결·되돌리기·도구 3개·도구 수 25 테스트 |
| SW-C 앱 | `app/lib/` (data/local·sync·repositories, features/home·scheduled(새)·calendar·session 판정, importing 라벨) | §4 §5, 만들기·수정 화면, 홈 카드, 달력 표시 | drift v4 마이그레이션 테스트, 시작 시 목표 복사, 판정 없음, 동기화 왕복, 위젯 테스트 |
