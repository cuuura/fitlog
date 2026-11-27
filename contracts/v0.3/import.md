# 가져오기 규칙 (A1 소유)

JSON 붙여넣기(앱)와 MCP 도구(`import_bundle`, `log_session` 등)는 **같은 가져오기 파이프라인**을 쓴다.

```
bundle → 검증 → 이름 해석 → 충돌 탐지 → (충돌 없음 또는 모두 해결됨) → 한 트랜잭션으로 저장 → ImportBatch
                                      → (해결 안 된 충돌 있음) → 저장 안 함, 충돌 목록 반환
```

## 1. 검증
- `import.schema.json` 위반이면 **전체 거부**(400 VALIDATION_FAILED, `details[].path`는 JSON 포인터). 부분 저장 없음
- 묶음 하나의 한도: 프로그램 10, 인스턴스 시작 5, 세션 200, 세트 5,000, 종목 100, 체중 1,000

## 2. 이름 해석 (종목)
`exercise` 참조가 `{ "name": ... }`이면 다음 순서로 찾는다.
1. 내 종목, 그다음 기본 종목에서 `name_ko` 또는 `name_en`이 **공백·대소문자 무시 완전 일치**
2. 묶음 안의 `exercises[]`에 같은 이름이 있으면 그것(새로 만들 종목)
3. 못 찾으면 충돌 `UNKNOWN_EXERCISE`. 비슷한 이름 후보를 최대 3개 `candidates`로 준다(v0.1 검색 규칙과 같은 정규화 후 부분 일치)

## 3. 충돌 종류와 해결

| 코드 | 언제 | 해결(resolution) | 기본값 없음 = 사용자가 골라야 함 |
| --- | --- | --- | --- |
| `UNKNOWN_EXERCISE` | 이름으로 종목을 못 찾음 | `MAP_TO`(exerciseId 지정), `CREATE`(type·primaryMuscle 필요), `SKIP`(그 종목 기록만 뺌) | 필수 |
| `SESSION_OVERLAP` | 가져올 세션의 현지 날짜(tz 기준)에 이미 세션이 있고, 시간이 겹치거나 시작 시각 차이가 3시간 이내 | `SKIP`, `KEEP_BOTH`, `REPLACE`(기존 세션 소프트 삭제 후 새로 저장) | 필수 |
| `BODY_SAME_DAY` | 같은 현지 날짜에 체중 기록이 이미 있음 | `SKIP`, `KEEP_BOTH`, `REPLACE` | 필수 |
| `PROGRAM_NAME_EXISTS` | 내 프로그램에 같은 이름이 있음 | `SKIP`, `KEEP_BOTH`(이름 뒤에 " (2)"), `REPLACE`(기존 프로그램 소프트 삭제. 진행 중 인스턴스는 스냅샷이라 영향 없음) | 필수 |
| `ID_EXISTS` | 묶음에 준 id가 이미 있고 내용이 다름 | `SKIP`, `REPLACE`, `KEEP_BOTH`(새 id) | 필수 |
| `PLAN_MISMATCH` | 세션의 `program.planSeq`가 그 인스턴스의 다음 회차와 다름 | `UNLINK`(프로그램 연결 없이 저장), `SKIP` | 필수 |
| `INSTANCE_NEEDS_VALUE` | 인스턴스 시작에 필요한 TM·작업 무게를 묶음에도 제안(suggest)에도 못 구함 | `SET`(값 지정), `SKIP` | 필수 |

- `INSTANCE_NEEDS_VALUE`의 `suggested`는 `{ "tm": { 키: kg | null }, "working": { 키: kg | null } }`. 그 인스턴스에 값이 필요한 키(엔진 requiredInputs)를 **모두** 넣고, 제안값을 모르는 키는 `null`. 필요 없는 쪽은 `{}`
- `SET` 해결은 `value: { "tm": { 키: kg }, "working": { 키: kg } }`. 묶음에 준 값과 합친 뒤에도 빠진 키가 있으면 여전히 미해결
- 같은 id·같은 내용이면 충돌이 아니라 `UNCHANGED`(아무것도 안 함). 그래서 **같은 묶음을 두 번 보내도 결과가 같다**(멱등)
- 충돌마다 서버가 결정적인 `conflictId`를 준다: `"{code}:{bundle 안 JSON 포인터}"` (예: `SESSION_OVERLAP:/sessions/3`). 같은 묶음이면 매번 같은 id
- 해결은 요청의 `resolutions: { conflictId: { action, exerciseId?, value? } }`로 준다. 해결 안 된 충돌이 하나라도 있으면 저장하지 않고 409 + 충돌 목록
- `onConflict` 일괄 지정(MCP 편의): `ASK`(기본, 위와 같음) | `SKIP_ALL`(모든 충돌 SKIP, `UNKNOWN_EXERCISE`는 `SKIP`) — `REPLACE` 일괄 지정은 없다(덮어쓰기는 항상 개별 선택)

## 4. 저장
- 모든 변경은 **한 트랜잭션**. 실패하면 아무것도 저장하지 않는다
- 저장 순서: 종목 → 프로그램 → 인스턴스 시작 → 세션(→ 끝난 프로그램 세션이면 v0.2 규칙대로 replay) → 체중
- 새로 만든 행과 REPLACE로 지운 행을 모두 `import_item`에 남긴다
- 만든 행의 `source`: 앱 붙여넣기 `AI_JSON`, MCP `AI_MCP`. `import_batch_id`를 채운다
- 동기화: 만든 행은 v0.1 규칙대로 `server_seq`를 받아 앱이 pull로 받는다

## 5. 출처 (AI-6)
- `ImportBatch`: `id`, `createdAt`, `channel`(`APP_JSON` | `MCP`), `clientName`(MCP는 OAuth 클라이언트 이름, 앱 붙여넣기는 사용자가 고른 AI 이름 또는 "직접 입력"), `summary`(종류별 개수), `revertedAt`
- 세션·프로그램·종목·체중 응답에 `importBatchId`, `source`가 붙는다(앱은 출처 배지 표시)

## 6. 되돌리기 (AI-6)
- `POST /v1/imports/{id}/revert`: 그 묶음이 **만든** 행을 소프트 삭제하고, 그 묶음이 **REPLACE로 지운** 행을 되살린다. 한 트랜잭션
- 되돌린 뒤 영향받은 인스턴스는 replay한다
- 묶음이 만든 행을 사용자가 나중에 고쳤어도 되돌리면 지운다. 앱은 되돌리기 전에 "이 묶음으로 만든 세션 N개, 프로그램 M개가 지워집니다"를 보여준다
- 되돌리기는 사용자만 한다(앱). MCP 도구로는 제공하지 않는다
- 이미 되돌린 묶음을 다시 되돌리면 200, 변화 없음

> v1.0 추가: `scheduledWorkouts`(하루짜리 예정 운동)와 충돌 `SCHEDULED_DUPLICATE`, 세션 `scheduledWorkoutId`는 `../v1.0/scheduled-workout.md` §7.
