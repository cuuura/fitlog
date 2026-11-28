# v1.2 편집·확장 계약

기능 ID: PRG-4·PRG-18(사용자 정의 증량 규칙, TM 갱신 방식), PRG-2(앱 내 편집기), PRG-7(종목 교체), LOG-9(슈퍼세트·드롭세트), LOG-12(예정일 리마인더), DAT-3(Strong·Hevy CSV), AI-4(AI 분석·조정 제안), 드래그로 바꾼 운동 순서 기억(LOG-14 후속).

원칙: 새 필드는 모두 선택, 기존 데이터·템플릿·replay 결과는 바뀌지 않는다(회귀 테스트 필수). 계산은 서버 엔진에만 둔다. 앱 UI는 `ui-consistency` 규칙과 `app/lib/core/ui/` 부품을 따른다(AlertDialog 직접 사용 금지).

## 1. 엔진: CUSTOM 규칙 (PRG-4, PRG-18)

```json
{
  "type": "CUSTOM",
  "target": "WORKING",
  "applyAt": "SESSION",
  "success": { "when": "ALL_SETS", "afterConsecutive": 1, "method": "ADD_KG", "amount": 2.5 },
  "failure": { "when": "ANY_SET", "afterConsecutive": 3, "method": "MULTIPLY", "amount": 0.9 },
  "steps": [ { "minReps": 1, "maxReps": 2, "amount": 0 }, { "minReps": 3, "amount": 2.5 } ]
}
```

| 필드 | 값 | 뜻 |
| --- | --- | --- |
| `target` | `WORKING`(기본) · `TM` | 바꿀 상태 값. 검증: 이 키를 쓰는 하중이 `PERCENT_TM`이면 `TM`, `WORKING`이면 `WORKING`이어야 한다 |
| `applyAt` | `SESSION`(기본) · `WEEK_END` · `CYCLE_END` | 판정 결과를 언제 반영할지. `CYCLE_END`는 `cycleWeeks` 필수 |
| `success.when` | `ALL_SETS`(기본) · `RANGE_TOP` · `AMRAP_REPS` | `ALL_SETS`: 판정 세트 모두 하한(`reps`) 이상. `RANGE_TOP`: 모두 `repsMax ?? reps` 이상. `AMRAP_REPS`: AMRAP 세트(`amrapSet` 또는 첫 AMRAP) 실제 횟수로 `steps` 표를 찾아 `amount` 적용(ADD_KG만) |
| `success.afterConsecutive` | 1~10, 기본 1 | 성공이 이만큼 연속돼야 반영(그 뒤 성공 연속 0) |
| `success.method` | `ADD_KG`(기본) · `ADD_PERCENT` · `E1RM` | `ADD_KG`: +amount kg. `ADD_PERCENT`: ×(1+amount). `E1RM`(PRG-18): 판정 세트 중 추정 1RM 최대값 × amount (amount 0.5~1.0, 사용자 설정 추정식, 반복 1~10 세트만). 결과가 지금보다 작으면 그대로 둔다 |
| `success.amount` | 수 | 위 방법의 값. `ADD_KG` −50~50, `ADD_PERCENT` 0~0.5 |
| `failure.when` | `ANY_SET`(기본) · `AMRAP_BELOW` | `ANY_SET`: 판정 세트 하나라도 하한 미달. `AMRAP_BELOW`: AMRAP 세트가 목표 미달 |
| `failure.afterConsecutive` | 1~10, 기본 3 | 실패가 이만큼 연속되면 반영(그 뒤 실패 연속 0) |
| `failure.method` | `MULTIPLY`(기본) · `SUBTRACT_KG` · `NONE` | `MULTIPLY`: ×amount(0.5~1.0). `SUBTRACT_KG`: −amount kg |
| `failure` | 생략 가능 | 생략하면 실패해도 무게 유지 |
| `steps` | `success.when = AMRAP_REPS`일 때 필수 | AMRAP_TABLE의 `table`과 같은 모양(`incrementKg` 대신 `amount`) |

판정 규칙
- 판정 세트 = 그 키의 본운동(`accessory: false`, `countsForProgression: true`) 세트 중 워밍업·드롭 세트 제외. 기록 없는 세트는 0회(기존과 같음)
- 회차 결과는 SUCCESS · FAIL · HOLD(둘 다 아님) 셋 중 하나. SUCCESS면 실패 연속 0, FAIL이면 성공 연속 0, HOLD면 둘 다 0
- `applyAt = SESSION`: 회차마다 바로 반영. `WEEK_END`/`CYCLE_END`: 그 기간의 회차 결과를 모아 기간 끝에 한 번 판정한다. 기간 안에 FAIL이 하나라도 있으면 기간 결과 FAIL, 아니면 SUCCESS가 하나라도 있으면 SUCCESS, 아니면 HOLD. 연속 횟수는 기간 단위로 센다. `AMRAP_REPS`는 기간 안 amount를 더해 기간 끝에 반영한다(AMRAP_TABLE WEEK_END와 같은 방식)
- 상태 추가(선택 필드, 없으면 빈 값): `ProgramState.successStreak: Map<String,Int>`, `ProgramState.periodResult: Map<String,String>`(기간 중 모은 결과), 기간 amount 합은 기존 `pendingTmDelta`를 키 공용으로 쓴다(이름과 달리 WORKING에도 사용)
- `plan(count)`의 "모두 성공 가정": CUSTOM은 SUCCESS 가정. 단 `RANGE_TOP`·`E1RM`은 무게 유지(HOLD) 가정
- 반올림: 상태 값은 기존처럼 소수 둘째 자리(r2). 계획 무게 반올림은 기존 규칙
- 시작 무게: `target = WORKING`이고 `success.when = RANGE_TOP`이면 DOUBLE처럼 시작 무게 선택(`optionalInputs`, 첫 회차 최소 무게로 확정)

검증 추가: 위 범위, `AMRAP_REPS`인데 `steps` 없음, `AMRAP_REPS`/`AMRAP_BELOW`인데 그 키 본운동에 AMRAP 세트 없음, `target`과 하중 불일치, `CYCLE_END`인데 `cycleWeeks` 없음 → 에러 경로 반환.

## 2. 스키마 추가 (LOG-9 표기)

| 위치 | 필드 | 뜻 |
| --- | --- | --- |
| `dayExercise` | `superset` (문자열 1~8) | 같은 날 같은 값끼리 슈퍼세트. 계산에는 영향 없음 |
| `set` | `drop` (bool) | 드롭 세트. 판정에서 제외(워밍업과 같음). `amrap`·`warmup`과 같이 쓸 수 없음 |

계획 출력: `PlannedExercise.superset`(없으면 생략), `PlannedSet.setType`(`"DROP"`일 때만, 아니면 생략). 앱은 세션 시작 시 각각 `supersetGroup`, `setType`으로 복사.

## 3. 프로그램 편집 API (PRG-2)

`PUT /v1/programs/{id}` 본문 `{ "name"?: string, "definition": ProgramDefinition }`
- 본인 프로그램만. 기본 템플릿(`owner_id NULL`)은 403 `FORBIDDEN`, 남의 것·없음은 404
- 검증·이름 풀기는 `POST /v1/programs`와 같다. 실패 400 형식도 같다
- 응답: `GET /v1/programs/{id}`와 같은 모양 + `activeInstanceIds: [uuid]`(이 프로그램의 ACTIVE·PAUSED 인스턴스)
- 진행 중 인스턴스는 바뀌지 않는다(시작 시점 스냅샷). 적용은 4절을 따로 호출
- 템플릿 고쳐 쓰기는 앱이 `GET` 정의를 받아 `family`·`variantLabel`을 빼고 `POST /v1/programs`로 새로 만든다(복사 API 없음)

## 4. 진행 중 프로그램 정의 교체 (PRG-2, 다음 회차부터 적용)

`PUT /v1/program-instances/{id}/definition` 본문 `{ "definition": ProgramDefinition, "tm"?: {key: kg}, "working"?: {key: kg} }`
1. 정의 검증(3절과 같음)
2. 지금 상태 S = replay 결과(seq = N)
3. 새 초기 상태 = S에서
   - `nextDayIndex`: 옛 정의의 다음 날 `key`가 새 정의에 있으면 그 인덱스, 없으면 `min(S.nextDayIndex, 새 days 수 − 1)`
   - `week`: 새 정의에 `cycleWeeks`가 있고 `week > cycleWeeks`면 1
   - 본문 `tm`·`working` 값으로 덮어씀
   - 새 정의의 필수 입력(`requiredInputs` − `optionalInputs`) 중 값이 없으면 400 `VALIDATION_FAILED`, 빠진 값마다 `details` 항목 `{path: "/tm/<key>" 또는 "/working/<key>", message}` (startInstance와 같은 방식)
4. 저장: `definition`=새 정의, `initial_state`=새 초기 상태, `base_seq`=N, `state`=새 초기 상태, `state_seq`=N, `day_order`={}
5. 이후 replay는 `planSeq <= base_seq`인 세션·건너뛰기를 무시한다(자동 건너뛰기 채우기도 그 뒤부터). 지난 세션 기록은 그대로 남고 다시 판정되지 않는다
- 응답: 인스턴스 보기(`GET /v1/program-instances/{id}`와 같음, `dayOrder` 포함)
- 끝나지 않은 다음 회차 세션이 이미 있으면 그 세션은 새 정의로 판정된다(앱이 확인창으로 알린다)

### 종목 교체 (PRG-7)
`POST /v1/program-instances/{id}/swap` 본문 `{ "liftKey": string, "exerciseId": uuid, "tm"?: kg, "working"?: kg }`
- 4절과 같은 방식으로 `lifts[liftKey].exercise = {id: exerciseId}`만 바꾼 정의로 교체(상태 값은 유지, 주어지면 그 키 덮어씀)
- `liftKey` 없음 400, 종목이 없거나 본인·공용이 아니면 404
- "이번만 교체"는 서버 API가 없다. 앱이 세션 종목의 `exerciseId`만 바꾸고 `liftKey`는 둔다(판정은 `liftKey`·`plannedSetKey` 기준이라 그대로 동작)

### 운동 순서 기억
`PUT /v1/program-instances/{id}/day-order` 본문 `{ "dayKey": string, "order": [int] }`
- `order`는 그 날 `exercises` 정의 인덱스의 순열. 빈 배열이나 원래 순서면 그 날 항목을 지운다. 아니면 400
- 응답 `{ "dayOrder": { "<dayKey>": [int] } }`
- 계획(`GET .../plan`, 인스턴스 `next`, MCP `get_plan`)의 `exercises`는 이 순서로 나온다. `plannedSetKey`는 정의 인덱스 그대로라 판정은 바뀌지 않는다
- 인스턴스 보기에 `dayOrder` 필드 추가

## 5. 슈퍼세트·드롭세트 기록 (LOG-9)

- `SessionExercise.supersetGroup`: 문자열 1~8 또는 null. 한 세션에서 같은 값끼리 묶음
- `WorkoutSet.setType`: `NORMAL`(기본) · `DROP` · `FAILURE`. `isWarmup`과 별개
- 동기화 push/pull, `PUT /v1/sessions/{id}`, 가져오기 묶음 스키마(선택 필드), 내보내기(JSON 필드, CSV 열 `superset_group`·`set_type`), MCP `log_session` 입력·`get_session` 출력에 추가
- 통계·PR·추정 1RM은 세트 종류와 관계없이 기존 계산(드롭 세트도 볼륨에 포함)
- 앱 휴식: 다음 세트가 DROP이면 휴식 타이머를 띄우지 않는다. 슈퍼세트는 묶음의 마지막 종목 세트 뒤에만 휴식(세트는 종목을 번갈아 진행)

## 6. CSV 가져오기 (DAT-3)

`POST /v1/imports/csv/preview` 본문 `{ "format": "STRONG"|"HEVY"|"AUTO", "csv": string, "weightUnit"?: "KG"|"LB", "tz": string }`
- `csv` 최대 5MB(본문 제한 안에서). `AUTO`는 머리글로 판별
- Strong: `Date, Workout Name, Duration, Exercise Name, Set Order, Weight, Reps, Distance, Seconds, Notes, Workout Notes, RPE`(쉼표 또는 세미콜론, 따옴표). `Set Order`가 `W`면 워밍업, `D`면 드롭, `F`면 실패. 무게 단위는 `weightUnit`(기본 KG)
- Hevy: `title, start_time, end_time, description, exercise_title, superset_id, exercise_notes, set_index, set_type, weight_kg|weight_lbs, reps, distance_km|distance_miles, duration_seconds, rpe`. `set_type` warmup/normal/dropset/failure → 워밍업/NORMAL/DROP/FAILURE, `superset_id` → `supersetGroup`
- 종목 이름 매칭: 대소문자·괄호 속 기구 표기를 정리해 기본 종목(이름·별칭)과 맞춘다. 흔한 영어 이름 사전(최소 60개)을 서버 코드에 둔다. 못 찾으면 가져오기 묶음에 새 사용자 종목으로 넣는다(괄호 기구로 종류 추정: Barbell→BARBELL, Dumbbell→DUMBBELL, Machine·Cable→MACHINE, 그 외 OTHER 등 기존 enum 안에서)
- 변환 결과를 기존 가져오기 묶음(v0.3 import.schema)으로 만들어 **기존 미리보기와 같은 처리**를 한다. 응답 = `POST /v1/imports/preview` 응답 + `csv: { format, sessions, sets, matchedExercises, newExercises: [name], skippedRows: [{line, reason}] }`. 확정은 기존 확정 경로 그대로(되돌리기 포함), `source`는 기존 가져오기 값
- 세션 id는 `(format, 시작 시각, 운동 이름)`에서 결정적으로 만든다(같은 파일 두 번 가져오면 기존 ID 충돌 처리로 걸린다)

## 7. AI 분석·조정 (AI-4)

분석·제안은 AI가 대화에서 한다. 서버는 판단에 필요한 데이터와 바꾸는 도구만 준다. 앱에 제안 화면은 두지 않는다.

새 MCP 도구(각각 `e2e/run.py` 호출 케이스 필수)
| 도구 | 입력 | 출력·동작 |
| --- | --- | --- |
| `get_program_analysis` | `instanceId`, `sessions`(1~20, 기본 8) | 종목 키별 `{key, exerciseId, exerciseName, ruleType, tm, working, failStreak, stalled, history:[{planSeq, date, value, result}]}`(value = 그 회차 뒤 상태 값, result = SUCCESS·FAIL·HOLD·NONE, stalled = 최근 3회 판정에서 값이 오르지 않음), 최근 회차 `[{planSeq, date, dayName, exercises:[{liftKey, planned:[{reps, repsMax, weightKg}], actual:[{reps, weightKg, rpe}], hit}]}]`, `adherence {completed, skipped, last28Days}` |
| `update_program` | `programId`, `definition`, `name?` | 3절 PUT과 같음 |
| `edit_program_instance` | `instanceId`, 그리고 `definition` 또는 `swap {liftKey, exerciseId}` 중 하나, `tm?`·`working?` | 4절 PUT definition 또는 swap과 같음 |

- 도구 설명에 "바꿀 내용을 사용자에게 먼저 보여 주고 동의를 받은 뒤 호출"을 적는다
- `contracts/v0.3/prompt.md`에 CUSTOM 규칙·`superset`·`drop` 예시와 분석→제안→동의→적용 흐름을 추가

## 8. 앱

### 8.1 프로그램 편집기 (B1, PRG-2·PRG-4)
- 새 폴더 `app/lib/features/program_editor/`. 진입 함수 `openProgramEditor(BuildContext, {String? programId, String? copyFromProgramId, String? instanceId})`(추가 시트의 '직접 만들기'는 다른 스레드가 이 함수로 연결)
- 정의는 `Map<String, dynamic>`으로 다뤄 편집기가 모르는 필드(weekly, family 등)를 그대로 보존한다
- 화면: 기본 정보(이름·설명·반올림·빈 봉·TM 비율·사이클 주 수) / 날 목록(추가·이름·요일·삭제·≡ 순서) / 날 안 종목(종목 고르기, 종목 키: 기존 키 선택 또는 새 키 자동, 보조 여부, 판정 포함 여부, 슈퍼세트 글자, 기본 휴식) / 세트 줄(개수·횟수·상한·하중 종류와 값·AMRAP·워밍업·드롭·휴식) / 종목 키별 증량 규칙(없음·LINEAR·DOUBLE·STAGES·AMRAP_TABLE·CYCLE·CUSTOM 폼). 주차별 덮어쓰기가 있는 세트는 "주차별 설정 있음(그대로 유지)" 표시
- 저장 전 `POST /v1/programs/validate`, 에러는 경로에 맞는 칸 아래 표시. 새로 만들기 `POST`, 고치기 `PUT`. 저장 후 `activeInstanceIds`가 있으면 확인창 "진행 중인 N개에도 다음 회차부터 적용할까요?" → 각 인스턴스 `PUT definition`, 빠진 입력(400 details `/tm/<key>`)이면 입력 시트로 값 받기
- 진입: 내 프로그램 행 ⋮ '편집', 프로그램(템플릿) 상세 앱바 ⋮ '복사해서 고치기', 인스턴스 상세 앱바 ⋮ '이 진행만 고치기'(instance 모드, 저장 = `PUT definition`)
- 미저장 이탈 확인(UnsavedGuard), 하단 고정 저장 버튼(BottomActionBar), 항목 ⋮(RowMenu), 짧은 입력은 FormSheet

### 8.2 세션 확장 (B2, LOG-9·PRG-7·순서 기억)
- drift 스키마 +1: 세션 종목 `supersetGroup`, 세트 `setType`. 동기화 DTO 왕복
- 진행 중 세션: 종목 ⋮ '슈퍼세트로 묶기'(다음 종목과 묶기/풀기, 묶음 색 띠와 글자), 세트 ⋮ '드롭 세트로'/'실패 세트로'/'일반 세트로', 세트 표에 D·F 표시. 슈퍼세트는 현재 세트 패널이 묶음 안 종목을 번갈아 안내. 휴식 규칙은 5절
- 프로그램 회차 시작 시 계획의 `superset`·`setType` 복사
- 종목 교체: 진행 중 세션 종목 ⋮ '종목 바꾸기' → 종목 고르기 → 프로그램 종목이면 시트에서 '이번만' / '앞으로 계속'(후자는 `POST swap`, 온라인 필요). 일반 종목은 바로 교체. 기록된 세트는 유지
- 순서 기억: 프로그램 회차를 끝낼 때 프로그램 본운동 순서가 계획 순서와 다르면 `PUT day-order`, 스낵바 "다음 회차부터 이 순서로 보여 드릴게요" + 되돌리기(되돌리면 이전 순서로 다시 PUT). 실패하면 조용히 넘어간다(다음 동기화 때 다시 시도하지 않음)
- 인스턴스 상세: 종목 키 행 ⋮ '종목 바꾸기'(swap)

### 8.3 가져오기·리마인더 (B3, DAT-3·LOG-12)
- 설정(데이터) → '다른 앱 기록 가져오기': 형식 선택(Strong·Hevy·자동), 파일 고르기(file_picker, .csv), 무게 단위(Strong만), 미리보기 요약(세션·세트 수, 새로 만들 종목 이름, 건너뛴 줄), 확정은 기존 가져오기 확정 흐름 재사용
- 리마인더(LOG-12)는 기기 로컬 알림(서버 푸시 없음): 설정 on/off(기본 off), 시각(기본 08:00), 알림 날(당일/전날 저녁). 진행 중 인스턴스 계획(`plan?count=8`의 `scheduledDate`)과 끝나지 않은 예정 운동에서 앞으로 14일 날짜를 모아 `zonedSchedule`. 앱 시작·동기화 후·설정 변경·프로그램 시작/일시정지 때 다시 예약. 알림 눌러 홈으로. 설정 값은 기기 저장(shared_preferences)
- Android 13+ 알림 권한·정확한 알람 권한 처리는 기존 휴식 타이머 방식 재사용

## 9. 테스트 벡터 (서버 필수)

| # | 상황 | 기대 |
| --- | --- | --- |
| C1 | CUSTOM WORKING SESSION ALL_SETS ADD_KG 2.5, 5x5 성공 | +2.5 |
| C2 | C1에 success.afterConsecutive 2, 성공·성공 | 첫 회 유지, 둘째 +2.5, 성공 연속 0 |
| C3 | failure ANY_SET 2회 MULTIPLY 0.9, 실패·실패 | ×0.9, 실패 연속 0 |
| C4 | failure 생략, 실패 5회 | 무게 유지 |
| C5 | ADD_PERCENT 0.05, working 100 성공 | 105 |
| C6 | TM, E1RM 0.9, AMRAP 100×8(EPLEY) | TM = r2(126.67×0.9)=114.0, 현재 TM보다 작으면 유지 |
| C7 | AMRAP_REPS steps(1~2:0, 3~4:2.5, 5+:5) WEEK_END, 주 3회 AMRAP 3·5·1 | 주 끝에 +7.5, FAIL 판정은 failure 규칙(AMRAP_BELOW) 따름 |
| C8 | WEEK_END ALL_SETS, 주 안에 성공·실패·성공 | 기간 FAIL(실패 연속 +1) |
| C9 | CYCLE_END cycleWeeks 3 | 사이클 끝에만 반영 |
| C10 | RANGE_TOP WORKING 시작 무게 없음 | 인스턴스 201, 첫 회 최소 무게로 확정 |
| C11 | 드롭 세트(set.drop) 미달 | 판정 영향 없음, 계획 `setType: DROP` |
| C12 | 검증: target 불일치, steps 없음, AMRAP 없음, CYCLE_END+cycleWeeks 없음, drop+amrap | 각 에러 경로 |
| C13 | 정의 교체: 3회 진행 뒤 days 순서 바꾼 정의로 PUT | base_seq 3, 다음 날 key 유지, 이전 세션 수정·이전 조정 있어도 상태 불변, FIXED_DATE 예정일 이어짐, 진행 중 N+1 세션 있으면 409 |
| C14 | 정의 교체: 새 종목 키 TM 없음 | 400 missingInputs, 주면 200 |
| C15 | swap 후 계획 exerciseId 바뀜, tm 유지 | |
| C16 | day-order [2,0,1] | 계획 exercises 순서 바뀜, plannedSetKey 그대로, 판정 같음 |
| C17 | 기존 템플릿 전체 replay·계획 | 변경 전과 같음(회귀) |
| C18 | Strong·Hevy 예시 CSV(테스트 리소스) | 세션·세트 수, W/D/F·superset 매핑, 새 종목(primaryMuscle 기본값), 250세션 → 묶음 2개, 확정 후 두 번째 미리보기 ID 충돌 |
| C19 | 세션 sync push/pull supersetGroup·setType 왕복, 잘못된 setType 400 | |

## 9.5 계획 검증 반영 (위 절보다 우선)

엔진
- `PerformedSet.setType` 추가(Replay가 세트 `set_type`을 넘김). `DROP`은 계획의 `drop` 세트든 앱에서 바꾼 세트든 **모든 규칙** 판정에서 워밍업처럼 제외. `FAILURE`는 일반 세트처럼 판정
- 한 회차에서 SUCCESS·FAIL 조건이 둘 다 참이면 **FAIL 우선**
- `AMRAP_REPS`: 그 회차 steps amount > 0이면 SUCCESS, 실패는 failure 규칙으로만 판정, 둘 다 아니면 HOLD. amount는 기간 결과와 관계없이 더해 기간 끝에 반영하고 실패 연속만 기간 결과로 센다(C7 기대값 그대로)
- `E1RM`은 `applyAt = SESSION`만 허용(검증 에러). 유효 세트(반복 1~10, 무게 > 0)가 없으면 HOLD
- 기간 안에 그 키 회차가 0개면 연속 횟수 변화 없음
- `ADD_PERCENT`·`MULTIPLY`는 반영 시점의 현재 값 기준
- `AMRAP_BELOW`의 목표 = 그 주에 펼친 세트의 `reps`(weekly 적용 후)
- 선택 시작 무게(`optionalInputs`, `weightOf`의 null, judge의 첫 회 최소 무게)는 DOUBLE과 CUSTOM `RANGE_TOP`+`WORKING`에 공통 적용. `plan()`의 HOLD 가정 되돌리기는 `working·failStreak·successStreak·periodResult·pendingTmDelta` 모두
- `weekEnd`·`cycleEnd`에 CUSTOM 분기 추가. `ProgramState` 새 필드는 기본값을 둬 기존 JSON·위치 생성자 호출이 깨지지 않게

정의 교체(4절)
- replay는 `afterSeq <= base_seq`인 조정(program_adjustment)도 무시
- 교체 시 `base_date` = 걸러질 이벤트(세션·건너뛰기) 중 마지막 날짜(없으면 NULL). `lastDate()`와 계획 `anchor`는 `max(걸러진 뒤 날짜, base_date)`
- 이 인스턴스에 `plan_seq = N+1`이고 끝나지 않은(ended_at NULL) 세션이 있으면 409 `CONFLICT`("진행 중인 회차를 끝내거나 지운 뒤 바꾸세요"). 앱은 그 문구를 보여 준다(8.1의 확인창 대신)
- 규칙 종류가 바뀌거나 없어진 키는 `failStreak·successStreak·periodResult·pendingTmDelta·stage`를 그 키만 비운다
- 내보내기: `planSeq <= base_seq` 세션은 프로그램 연결(`programInstanceId·planSeq·planDayKey`)을 빼고 내보내고, 인스턴스 시작 값은 교체 뒤 `initial_state` 기준. `ImportAnalyzer`의 기존 `InstInfo.baseSeq`는 이름을 바꿔 혼동을 없앤다

순서 기억
- 순서 적용은 `plannedWorkouts` 한 곳(계획·`next`·MCP `get_plan` 공용)에서 `plannedSetKey`의 종목 인덱스로 정렬. 그 주 계획에서 빠진 인덱스는 건너뜀. 보조운동(`acc:`)은 그대로 뒤
- 정의 교체 시 `day_order` 비움(위 4절과 같음)

CSV 가져오기(6절 대체)
- `csv` 최대 4MB
- 응답: `{ csv: {format, sessions, sets, matchedExercises, newExercises, skippedRows}, chunks: [{ bundle, preview }] }`. 기존 한도(세션 200·세트 5000·종목 100, 세션당 종목 30·종목당 세트 50)를 넘지 않게 **날짜순으로 묶음을 나눈다**. 한도 넘는 한 세션은 잘라서 skippedRows에 사유. 앱은 각 `bundle`을 기존 `POST /v1/imports`로 차례로 확정
- 새 종목 `primaryMuscle`은 사전 값, 모르면 기존 enum의 기타/전신 값. 새 종목 id는 `(format, 정리된 이름)`에서 결정적으로
- 가져오기 스키마 허용 키(`keys()`)와 중복 검출 지문(`fpSet`)에 `supersetGroup`·`setType` 추가

## 10. 작업 분할 (Opus 리드 1 = 이 스레드 + Sonnet 3씩, 서버 먼저 → 앱)

서버 (골격: V7 마이그레이션·Tables.kt 컬럼은 리드가 main에 먼저 둔다)
| WP | 소유 파일 | 범위 |
| --- | --- | --- |
| A1 엔진·스키마 | `engine/`, `program/schema/`, `resources/schemas/program.schema.json`, `contracts/v1.2/program.schema.json`, `contracts/v0.3/prompt.md` | 1·2절, 벡터 C1~C12·C17 |
| A2 기록·가져오기 | `session/`, `sync/`, `importing/`(CSV 새 파일), `export/`, import 스키마, MCP `log_session`·`get_session` 필드 | 5·6절, C18·C19 |
| A3 편집 API·AI 도구 | `program/catalog/ProgramRoutes.kt`(PUT), `program/instance/`(definition·swap·day-order·replay base_seq), MCP 새 도구 3개, `e2e/run.py` | 3·4·7절, C13~C16, e2e |

앱
| WP | 소유 파일 | 범위 |
| --- | --- | --- |
| B1 편집기 | `features/program_editor/`(새), `core/api` 프로그램 편집 메서드, 진입 메뉴(programs_page·instance_detail_page·program_detail_page의 ⋮ 항목만) | 8.1 |
| B2 세션 확장 | `features/session/`, drift·sync, `instance_detail_page.dart` 종목 바꾸기 | 8.2 |
| B3 가져오기·리마인더 | `features/importing/` 또는 새 `features/csv_import/`, `features/settings/`, 새 `core/reminders/` | 8.3 |

다른 스레드와 공유 파일(`engine/Model.kt`, `ProgramValidator`, 스키마, `InstanceDtos.kt`, `program_dto.dart`)은 **필드 추가만** 하고 기존 필드는 바꾸지 않는다. 푸시 전 origin/main 병합.

## A2 구현 메모

- CSV 사전 위치: `server/.../importing/CsvExerciseDictionary.kt`(시드 id 직접 매핑, 정규화 키는 단어 정렬·복수형 제거·괄호 단어 포함). 기구 단어가 다른 괄호 표기는 괄호 없는 이름으로 되돌려 찾지 않는다.
- 내 종목 이름(한/영)이 사전·기본 종목보다 먼저 매칭된다.
- 세션·새 종목 id 해시에는 userId를 포함한다(다른 사용자가 같은 파일을 가져올 때 PK 충돌 방지).
- 새 종목 type: 이름의 기구 단어 → 없으면 기록 모양(횟수 없이 시간·거리만=CARDIO, 무게>0=MACHINE, 그 외 BODYWEIGHT). CARDIO는 primaryMuscle CARDIO, 사전에 없으면 FULL_BODY. BODYWEIGHT·BAND의 무게는 addedWeightKg.
- 4MB 초과는 413(`VALIDATION_FAILED`), 형식 오류·머리글 판별 실패·잘못된 format/weightUnit/tz는 400 `VALIDATION_FAILED`. 한 세션 종목 30·종목당 세트 50 초과분은 skippedRows.
- Strong `Rest Timer` 행·빈 세트 행은 skippedRows. 세션 note = 운동 이름 + 줄바꿈 + 메모.
- 내보내기 JSON 세트는 `setType`을 항상, 종목은 `supersetGroup`이 있을 때만 낸다. CSV 열은 맨 끝에 추가.
