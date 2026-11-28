# 신체·근력 수치 (BDY-2, BDY-5, BDY-6) — 서버 A4 · 앱 B4 계약

2026-11-28 작성. 사용자 확정안은 기능 정의서 '신체·근력 수치 입력 상세'. 이 문서가 구현 기준이다.
이미 된 것(앱 22ede32·4d6572a·c9c4c26): MY 탭 '3대 운동 1RM' 카드, `/me/big3` 추이, `one_rm_sheet.dart`(온라인 REST).
3대 고정 종목 id: 스쿼트 `019b76da-4000-7000-8000-000000000001`, 벤치프레스 `...000003`, 데드리프트 `...000006` (앱 `core/big3.dart`, 서버는 상수 `Big3`로 둔다).

## 1. DB V8 (`V8__body_strength.sql`)

- `body_measurement`
  - `weight_kg` NULL 허용
  - `body_fat_pct numeric(4,1)` (3~60), `skeletal_muscle_kg numeric(5,2)` (10~80) 추가
  - CHECK: 셋 중 하나 이상 NOT NULL. 체중 범위 20~300
- `one_rm_measurement`
  - `method text NOT NULL DEFAULT 'TESTED' CHECK (method IN ('TESTED','CALCULATED'))`
  - `reps integer NULL CHECK (reps BETWEEN 1 AND 10)`, `source_weight_kg numeric(6,2) NULL`
  - CHECK: `method='CALCULATED'` 이면 reps·source_weight_kg NOT NULL
  - `updated_at timestamptz NOT NULL DEFAULT now()`, `server_seq bigint NOT NULL DEFAULT nextval('change_seq')`
  - 가져오기 출처 열이 다른 동기화 테이블에 있으면(`import_batch_id` 등) 같은 모양으로 추가
  - 범위 1~500kg(기존 > 0 에서 좁힘. 기존 행은 그대로 두고 새 CHECK 는 NOT VALID 로)
- `exercise`
  - `inference_base_exercise_id uuid NULL REFERENCES exercise(id)`, `inference_ratio numeric(4,3) NULL`
  - 시드(V2 종목 이름으로 찾아 UPDATE): 오버헤드프레스=벤치×0.65, 인클라인 벤치프레스=벤치×0.80, 클로즈그립 벤치프레스=벤치×0.90, 바벨 로우=벤치×0.75, 프론트 스쿼트=스쿼트×0.80, 루마니안 데드리프트=데드×0.65, 스모 데드리프트=데드×1.00. 시드에 없는 종목은 건너뛴다(어떤 것을 건너뛰었는지 커밋 메시지에)

## 2. 동기화

- `body_measurement` payload: `measuredAt`, `weightKg?`, `bodyFatPct?`, `skeletalMuscleKg?`, `source?`, (pull 전용) `importBatchId?`. 옛 앱이 `weightKg`만 보내도 그대로 동작
- 새 entity `one_rm_measurement` (부모 없음, 같은 LWW 규칙): `exerciseId`, `weightKg`, `measuredAt`, `method`(기본 TESTED), `reps?`, `sourceWeightKg?`, `note?`, (pull 전용) `importBatchId?`
- 검증 실패는 `rejected`/`VALIDATION_FAILED`. 다른 사용자 종목 id 는 `FORBIDDEN`
- REST `GET/POST/DELETE /v1/exercises/{id}/one-rm` 은 유지하고 새 필드(method·reps·sourceWeightKg) 를 받고 돌려준다. REST 로 쓴 행도 server_seq 가 올라가 pull 에 나온다
- 환산 값: 클라이언트가 `weightKg`(설정 추정식으로 계산)를 보낸다. 서버는 범위만 검사. MCP·가져오기에서 CALCULATED 인데 weightKg 가 없으면 서버가 사용자 추정식으로 계산해 채운다

## 3. 현재 1RM 과 출처

종목 하나의 '현재 1RM' 우선순위: 실측(TESTED) > 환산(CALCULATED) > 기록 자동 추정(최근 90일 최고 e1RM, 기존 STA-3) > 3대에서 유추(3대 외 종목, 비율이 있을 때만, 기준 종목의 현재 1RM×비율, 본인 기록이 하나도 없을 때만). 같은 종류 안에서는 최근 값.

출처 문자열(OneRmSource): `MEASURED`(=TESTED, 기존 이름 유지), `CALCULATED`, `ESTIMATED`, `INFERRED`. 기존 응답의 `oneRmSource` 를 쓰는 곳(종목 기록 요약, 프로그램 시작 제안 PRG-14, preview) 모두 이 규칙으로 바꾼다. INFERRED 일 때 `inferredFrom`(기준 종목 id)·`inferenceRatio` 를 같이 준다.

## 4. 새 REST

### `GET /v1/me/strength-summary`
```json
{
  "lifts": [
    {"key": "SQUAT", "exerciseId": "...01", "oneRmKg": 140.0, "source": "MEASURED", "measuredAt": "2026-11-20T..Z"},
    {"key": "BENCH", "exerciseId": "...03", "oneRmKg": 100.0, "source": "ESTIMATED", "measuredAt": null},
    {"key": "DEADLIFT", "exerciseId": "...06", "oneRmKg": null, "source": null, "measuredAt": null}
  ],
  "totalKg": null,
  "totalIncludesEstimate": true,
  "bodyweightKg": 80.0,
  "bodyweightMultiple": null
}
```
- 한 종목이라도 값이 없으면 `totalKg`·`bodyweightMultiple` = null. `totalIncludesEstimate` = ESTIMATED 가 하나라도 섞였는지(CALCULATED 는 추정 아님)
- `bodyweightMultiple` = totalKg ÷ 최신 체중(소수 둘째 자리), 체중 없으면 null

### `GET /v1/program-instances/tm-suggestions?exerciseId=<id>&oneRmKg=<선택>`
진행 중(ACTIVE·PAUSED) 인스턴스 중 TM 입력(Needs.TM)이 그 종목을 가리키는 키마다 한 줄. oneRmKg 가 없으면 3절 현재 1RM.
```json
{"oneRmKg": 150.0, "suggestions": [
  {"instanceId": "...", "programName": "...", "liftKey": "squat", "currentTmKg": 125.0, "suggestedTmKg": 135.0, "tmPercent": 0.9}
]}
```
- suggestedTm = 1RM × 그 정의의 tmPercent(없으면 0.9), 정의의 roundingKg(기본 2.5) 반올림. current 와 같으면 빼다
- 수락은 기존 `PATCH /v1/program-instances/{id}/adjust` (`{"tm": {liftKey: kg}}`). 서버는 자동으로 바꾸지 않는다

## 5. 가져오기·MCP·삭제·내보내기

- import 묶음: `bodyMeasurements[]` 에 `bodyFatPct`·`skeletalMuscleKg`(weightKg 선택), 새 `oneRmMeasurements[]`(exerciseId 또는 exerciseName, weightKg, measuredAt, method, reps, sourceWeightKg, note). 같은 종목·같은 시각·같은 무게는 충돌 `DUPLICATE` 계열(기존 신체 측정과 같은 방식)
- MCP: `log_body_measurement`(weightKg·bodyFatPct·skeletalMuscleKg 중 하나 이상, measuredAt 선택) 추가, `log_body_weight` 는 같은 동작의 옛 이름으로 유지. `log_one_rm`(exerciseId|exerciseName, weightKg 또는 reps+sourceWeightKg, method 생략 시 reps 있으면 CALCULATED, measuredAt·note 선택) — 응답에 tm-suggestions 결과를 같이 담고 "TM 은 앱에서 수락해야 바뀐다" 문구. `get_strength_summary`. 세 도구 모두 `e2e/run.py` 호출 케이스 필수
- `request_deletion` 대상에 `one_rm_measurement` 추가(앱 승인 화면 라벨 '1RM 기록')
- 내보내기 JSON 에 oneRmMeasurements, 신체 측정 새 열. CSV `kind=one_rm` 추가, `kind=body` 에 body_fat_pct·skeletal_muscle_kg 열

## 6. 앱 (B4)

- drift: body 테이블 weightKg nullable + bodyFatPct·skeletalMuscleKg, 새 one_rm 테이블(동기화 대상, 같은 큐). 마이그레이션 테스트 포함
- 1RM 읽기·쓰기는 로컬 우선(오프라인 저장, 동기화로 올라감). 종목 기록 화면·MY 3대 카드·`/me/big3` 모두 같은 저장소를 쓴다. 자동 추정(ESTIMATED)은 기존 온라인 progress 를 계속 쓰고, 오프라인이면 측정값만
- MY 탭 '신체 수치' → '내 수치': 위 체중·BMI(분류: 18.5 미만 저체중 / 23 미만 정상 / 25 미만 비만 전 단계 / 이상 비만, '근육량이 많으면 높게 나와요' 한 줄)·체지방률·골격근량 카드, 아래 3대 1RM·합계·체중 배수 카드(이미 있는 카드 확장). 카드마다 + 로 공통 입력 시트(`core/ui` FormSheet), 누르면 이력·그래프
- 신체 측정 입력 시트: 체중·체지방률·골격근량 한 장, 하나만 있어도 저장. 범위 밖 저장 불가, 직전 값과 20% 넘게 다르면 `confirmAction` 으로 '맞나요?'
- 1RM 입력 시트: '실측 | 환산' 전환. 환산은 무게×횟수(1~10) → 설정 추정식 결과를 미리 보여 줌. 저장값에 방식 라벨(실측/환산)
- 저장 뒤(온라인일 때) tm-suggestions 를 불러 제안이 있으면 시트로 'TM 125 → 135kg로 바꿀까요?' 인스턴스별 체크, 수락 시 adjust. 오프라인이거나 실패면 조용히 넘어감(다음에 종목 기록 화면에서 다시 제안하지 않음)
- 첫 설정 화면: 첫 로그인·동의 뒤 한 번. 키·체중·3대 1RM(실측) 선택 입력, 건너뛰기. 이미 값이 있거나 한 번 본 계정이면 안 띄움(로컬 설정 플래그)
- '3대에서 유추' 라벨: 종목 기록 화면과 프로그램 맞추기 화면의 1RM·제안 출처가 INFERRED 면 회색 라벨. CALCULATED 는 '환산'
- 앱 DTO 의 OneRmSource 에 CALCULATED·INFERRED 추가(모르는 값은 지금처럼 null)
- UI 는 `ui-consistency` 규칙(AlertDialog 직접 사용 금지, 입력은 FormSheet, 한 건 삭제는 즉시+되돌리기)

## 7. 테스트 기준

서버: 범위 검증, 우선순위(실측>환산>자동>유추), 비율 없는 종목은 유추 안 함, 합계 '추정 포함'·빈 값, 동기화 LWW·pull 에 one_rm, tm-suggestions(TM 키 매핑·반올림·같으면 제외·FINISHED 제외), 가져오기·내보내기·삭제 요청, MCP 3개(e2e 포함).
앱: drift 마이그레이션, 오프라인 저장→동기화, 시트 검증·20% 확인, 환산 계산, TM 제안 수락→adjust 호출, 첫 설정 건너뛰기, 라벨 표시.
