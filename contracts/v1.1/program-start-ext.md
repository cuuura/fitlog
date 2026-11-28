# v1.1 프로그램 시작 확장 계약 (프로그램 추가 개편 3단계)

2026-11-28 사용자 승인안(`/mnt/project-files/design/program-add-impl-plan.md` 3단계) 구현 계약이다. 새 필드·엔드포인트는 모두 선택이라 기존 앱·템플릿·인스턴스는 그대로 동작한다. `schemaVersion` 1 그대로, DB 마이그레이션 없음.

| 절 | 내용 | 담당 WP |
| --- | --- | --- |
| 1 | 시작 전 미리 계산 `POST /v1/programs/{id}/preview` | S1 서버 |
| 2 | 시작할 때 요일 바꾸기 `weekdays` | S1 서버 |
| 3 | 회당 시간 `sessionMinutes`·`estimatedMinutes` | S1 서버 |
| 4 | 자동 계산 규칙 `lifts.<k>.derive`, 첫 운동에서 정하기 `lifts.<k>.fromFirstSession` | S2 서버(엔진·검증·템플릿) |
| 5 | 앱: 맞추기 화면 첫 운동 세트·무게, 자동 계산 묶음, 요일 바꾸기, 보조 종목 카드, 회당 시간 표시 | S3 앱 |

## 1. 시작 전 미리 계산

`POST /v1/programs/{id}/preview` (인증 필요, 저장하지 않음, 템플릿과 내 프로그램 모두)

요청 본문은 `StartInstance`에서 `id`·`programId`를 뺀 모양에 `count`를 더한다.
```json
{ "startDate": "2026-12-01", "tz": "Asia/Seoul", "skipPolicy": "FIXED_DATE",
  "tm": { "squat": 100 }, "working": {}, "weekdays": { "A": "TUE" }, "count": 1 }
```
- `count` 1~4, 기본 1. `startDate` 없으면 사용자 오늘(tz 기준, tz 없으면 UTC). `skipPolicy` 기본 SHIFT
- 검증은 시작(`POST /v1/program-instances`)과 **똑같다**: 필수 입력이 빠지면 400 `tm.<key>`·`working.<key>`, 무게 범위, `weekdays`(2절), FIXED_DATE 요일 요구. 앱은 필수 칸이 다 차면 부른다
- 응답 200:
```json
{
  "workouts": [ { "planSeq": 1, "dayIndex": 0, "dayKey": "A", "dayName": "A 날", "week": 1, "cycle": 1,
                  "scheduledDate": "2026-12-02", "confirmed": true, "estimatedMinutes": 55,
                  "exercises": [ /* PlannedExercise, 인스턴스 계획과 같은 모양 */ ] } ],
  "inputs": { "tm": { "squat": 100, "bench": 70 }, "working": { "row": 40 } },
  "derived": [ "bench", "row" ]
}
```
- `workouts`는 인스턴스를 만들었다면 `GET /program-instances/{id}/plan?count=N`이 돌려줄 것과 같다(보조 종목은 없음). `scheduledDate`는 FIXED_DATE일 때만, 첫 회차는 `startDate` 당일부터 찾는다(인스턴스와 같은 규칙)
- `inputs`: 실제로 시작될 값(4절 자동 계산이 채운 값 포함, 반올림 후). `derived`: `inputs` 중 요청에 없어서 서버가 자동 계산으로 채운 키
- 없는 프로그램 404. 레이트 리밋은 API 버킷

## 2. 시작할 때 요일 바꾸기

`StartInstance`(와 1절 preview)에 선택 필드:
```json
"weekdays": { "A": "MON", "B": "WED", "C": "FRI" }
```
- 키는 `days[].key`, 값은 `MON`~`SUN`. 일부 날만 줘도 된다(안 준 날은 정의 그대로)
- 모르는 날 키 → 400 `weekdays.<key>`, 모르는 요일 값 → 400 `weekdays.<key>`
- 적용 후 같은 요일에 두 날 이상 → 400 `weekdays` ("two days on the same weekday")
- 적용 결과는 **인스턴스에 저장되는 정의 사본**(`program_instance.definition`)의 `days[].weekday`에만 반영. 원래 프로그램(`program.definition`)은 그대로
- FIXED_DATE 요일 요구 검사(`requireWeekdays`)는 적용 **후** 정의로 한다. 요일 없던 프로그램도 모든 날에 요일을 주면 FIXED_DATE로 시작할 수 있다
- 같은 id 재전송(멱등)은 기존처럼 처음 만든 그대로 돌려준다
- MCP `start_program` 도구에 같은 선택 인자 `weekdays`(객체)를 더한다. e2e/run.py의 start_program 호출에 `weekdays` 한 건을 넣는다

## 3. 회당 시간

어림 규칙(서버 한 곳, `program/Durations.kt` 같은 순수 함수):
- 본 세트: 작업 40초 + 휴식. 휴식 = `PlannedSet.restSec`, 없으면 보조(`accessory: true`) 90초, 그 외 150초
- 워밍업 세트: 작업 30초 + 휴식 60초(`restSec` 있으면 그것)
- 각 종목 마지막 세트 뒤 휴식은 빼고, 종목 바꿈마다 2분을 더한다
- 합계를 분으로 올림하고 5분 단위로 반올림(최소 5)

노출:
- `PlannedWorkout.estimatedMinutes` (정수, 인스턴스 `next`·`/plan`·preview 모두). 보조 종목 포함
- `ProgramSummary.sessionMinutes` (목록·상세 `Program` 포함): `{ "min": 45, "max": 70 }`. 계산: 필수 입력을 모두 100kg으로 둔 가짜 상태로 `plan(count = days × max(cycleWeeks ?: 1, 1))`(최대 64)을 펼쳐 회차별 어림의 최소·최대. 계산 실패 시 생략(null). 프로세스 안에서 정의 텍스트 기준으로 캐시해도 된다
- MCP 프로그램 목록·상세 응답에도 `sessionMinutes` 포함(새 도구 아님)

## 4. 자동 계산 규칙과 첫 운동에서 정하기

`lifts.<key>`에 선택 필드 두 개(스키마 사본 `program.schema.json`, 서버 `resources/schemas/program.schema.json` 같이 갱신):
```json
"lifts": {
  "squat": { "exercise": { "name": "스쿼트" } },
  "frontSquat": { "exercise": { "name": "프론트 스쿼트" }, "derive": { "from": "squat", "ratio": 0.8 } },
  "curl": { "exercise": { "name": "바벨 컬" }, "fromFirstSession": true }
}
```
### derive (파생 시작 무게)
- 뜻: 이 종목의 시작 값(이 키가 요구하는 TM 또는 WORKING)을 시작 때 비우면 `from` 종목 시작 값 × `ratio`로 채운다. `from`의 시작 값은 `from` 키가 요구하는 값(TM이면 tm, WORKING이면 working)이다
- 반올림: `roundingKg` 단위 내림(floor). 0 이하이면 `roundingKg`
- 검증: `from`은 lifts의 다른 키, 자기 자신·다른 derive 키를 가리키면 에러(사슬 금지), `from`의 상태 키가 필수 입력이어야 함, `ratio` 0.05~2.0, 이 키가 `tmFrom`을 가지면 에러(이미 다른 키 TM을 공유). 이 키 자체가 입력을 요구하지 않으면(하중이 FIXED 등) 에러
- 상태 키 기준: derive는 `stateKey`로 푼 이 종목의 상태 키에 적용된다
- 엔진: `optionalInputs`에 derive 키 포함. `initialState`는 빠진 derive 키를 위 규칙으로 채운다(사용자가 준 값이 있으면 그것). base가 없으면(from도 비었고 from이 선택 키인 경우) 그 키는 비운 채 시작(4절 fromFirstSession처럼 null 무게, 첫 완료에서 결정)
- 제안 API `GET /programs/{id}/suggest` 항목에 `derivedFrom`(문자열)·`derivedRatio`(숫자) 추가(derive 키만), `optional: true`. 기록 기반 `suggestedKg`는 그대로 계산(있으면 앱이 그 값을 먼저 채움)

### fromFirstSession (첫 운동에서 정하기)
- WORKING 키에만(TM 키면 검증 에러). 시작 때 비워도 되고(`optional: true`), 비우면 계획 무게 null, 그 키의 첫 완료 회차에서 판정 세트 중 무게 있는 세트의 최소 무게를 `working`으로 정한 뒤 그 규칙(LINEAR·STAGES·DOUBLE 등)의 판정을 그대로 한다. DOUBLE의 기존 동작을 모든 WORKING 규칙으로 넓힌 것
- AMRAP_TABLE·CYCLE은 TM 기준이라 해당 없음
- replay 결정적

### 템플릿 지정
- 템플릿 20종 중 보조·변형 종목이 주 종목 무게에서 흔히 유추되는 곳에 `derive`, 기록 없으면 처음 정하는 게 자연스러운 고립 보조에 `fromFirstSession`. 지정 목록과 비율 근거는 이 문서 끝 "부록 A"에 S2가 적는다
- 기존 인스턴스는 저장된 정의 사본을 쓰므로 영향 없음

## 5. 앱

- 맞추기 화면 첫 운동 카드: 필수 칸이 다 차면 preview(`count: 1`)를 불러 세트×횟수@무게를 보여준다(입력 멈춘 뒤 400ms, 진행 중 요청은 최신 것만 반영). 칸이 비었거나 실패·오프라인이면 기존(날짜·종목)으로 보이고 "무게를 채우면 세트가 보여요" 한 줄. 앱은 무게를 따로 계산하지 않는다
- 시작 무게 카드: `derivedFrom` 키는 "자동 계산" 접힌 묶음(값은 preview `inputs`, 직접 고치면 그 값을 보냄, 근거 "<from> × 80%"). `fromFirstSession`·DOUBLE 선택 키는 "첫 운동에서 정하기" 안내
- 일정 카드: 날마다 요일 칩으로 바꾸기. 바꾼 요일은 겹침 알림·첫 운동 날짜·preview·시작 요청 `weekdays`에 반영. 같은 요일 두 날은 칩에서 막는다
- 보조 종목 카드(접힘, 선택): 날마다 보조 종목 추가(기존 종목 고르기 화면·세트·횟수·무게). 시작 성공 뒤 `PUT /program-instances/{id}/accessories`로 저장. 실패해도 시작은 성공으로 두고 안내
- 회당 시간: 추가 시트 카드와 맞추기 화면에 "회당 약 45~70분"(sessionMinutes), 첫 운동 카드에 "약 55분"(estimatedMinutes). 값 없으면 숨김
- 기간과 단계·RPE 카드는 v1.2 스레드의 PRG-17·PRG-19 필드가 들어온 뒤(이번 범위 아님)

## 부록 A. 템플릿 지정

기본 템플릿 20종 중 근거가 분명한 곳만 지정했다(기존 인스턴스는 저장된 정의 사본이라 영향 없음). 모두 "비우면 채운다"일 뿐 사용자가 값을 주면 그 값이 우선이다.

### derive

| 템플릿 | 종목 키 | 규칙 | 근거 |
| --- | --- | --- | --- |
| gzclp | `squat_t2`·`bench_t2`·`ohp_t2`·`deadlift_t2` | 같은 종목 T1 키 × 0.65 | GZCLP 안내의 T2 시작 무게 "T1 시작 무게의 약 65%". 반올림 내림이라 보수적 |
| phul-4day | `front_squat` | `squat` × 0.8 | 프런트 스쿼트는 백 스쿼트의 약 80~85%로 보는 일반 코칭 관례의 하한 쪽 |
| phul-4day | `incline_bb` | `bench` × 0.8 | 인클라인 벤치는 플랫 벤치의 약 80~85% 관례의 하한 쪽 |
| reddit-ppl-6day | `bench_vol` | `bench` × 0.8 | 근비대일(8~12회)은 근력일(5회) 무게보다 가벼움. 5RM→8RM 환산(약 88%)보다 낮게 |
| reddit-ppl-6day | `ohp_vol` | `ohp` × 0.8 | 위와 같음 |
| reddit-ppl-6day | `rdl`·`rdl2` | `deadlift` × 0.6 | 루마니안 데드는 데드리프트의 약 60~70%, 8~12회 구간이라 하한 쪽 |
| rippler-12week | `squat_t2` | `squat` × 0.8 | 프런트 스쿼트 변형(TM). 위 프런트 스쿼트 관례와 같음 |
| rippler-12week | `bench_t2` | `bench` × 0.8 | 인클라인 벤치 변형(TM). 위와 같음 |
| rippler-12week | `deadlift_t2` | `deadlift` × 0.7 | 루마니안 데드 변형(TM). RDL 약 60~70%의 상단 (TM 기준이라 약간 높게) |

phul-4day의 `bench`·`squat`은 DOUBLE이라 시작 때 비울 수 있다. 그 경우 파생 키도 비운 채 시작하고 첫 운동에서 정해진다(두 키 모두 DOUBLE이라 가능).

### fromFirstSession

WORKING 키 중 기록이 없으면 처음 정하는 게 자연스러운 고립 보조(컬·레이즈·푸시다운·페이스 풀·카프·트라이셉스 익스텐션·플라이·풀오버)에 붙였다. 모두 DOUBLE 규칙이라 DOUBLE만으로도 시작 때 비울 수 있었으며, 이 표시는 앱의 "첫 운동에서 정하기" 안내와 `suggest`의 `optional`을 명시한다.

| 템플릿 | 종목 키 |
| --- | --- |
| dumbbell-home-3day | `curl`, `pullover`, `lateral` |
| phul-4day | `curl`, `skull`, `calf`, `fly`, `lateral`, `incline_curl`, `tri_ext` |
| ppl-3day | `lateral`, `pushdown`, `face_pull`, `db_curl`, `calf` |
| reddit-ppl-6day | `face`, `hammer`, `curl`, `pushdown`, `overext`, `lat`, `calf` 및 각 `…2` |
| rippler-12week | `pushdown`, `lateral`, `face_pull`, `calf` |
| upper-lower-4day | `db_curl`, `pushdown`, `lateral`, `oh_tri`, `hammer`, `calf` |

## 부록 B. 구현 메모 (S2)

- 검증 추가 규칙: `derive`와 `fromFirstSession` 모두 `tmFrom`과 함께 못 쓴다. `fromFirstSession`은 그 키에 LINEAR·STAGES·DOUBLE 규칙이 있어야 한다(없으면 정할 수 없음). `from`이 비워 시작할 수 있는 키(DOUBLE·fromFirstSession)면 파생 키는 WORKING이면서 LINEAR·STAGES·DOUBLE 규칙이 있어야 한다. `from`이 가리키는 상태 키가 파생 키 자신이거나 또 다른 파생 키면 에러.
- 판정 시점 최소 무게는 워밍업 제외, 무게가 0보다 큰 세트만 본다. 무게 기록이 없으면 정해지지 않고 다음 회차로 미룬다.
