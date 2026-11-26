# 동기화 — v0.2 추가분

v0.1 `sync.md` 규칙은 그대로다. 아래만 더한다.

## 동기화 대상 필드 추가
- `workout_session` payload: `programInstanceId`, `planSeq`, `planDayKey`
- `session_exercise` payload: `liftKey`, `accessory`
- `workout_set` payload: `plannedSetKey`, `targetReps`, `targetWeightKg`, `isAmrap`
- 프로그램·인스턴스·건너뛰기·보조운동·1RM 측정은 **동기화 대상이 아니다**(REST 전용, 온라인에서만 변경)

## 계획 캐시 (앱 B2)
- 앱은 활성 인스턴스마다 `GET /v1/program-instances/{id}/plan?count=3` 결과를 로컬에 저장한다. 갱신 시점: 앱 시작, 포그라운드 복귀, 세션 종료 후 동기화 직후, 인스턴스 변경 후
- 오프라인에서 세션을 시작하면 캐시된 계획 중 **아직 쓰지 않은 가장 앞 planSeq**를 쓴다. 캐시를 다 쓰면 마지막 계획의 무게·횟수를 그대로 쓰고 planSeq는 이어서 붙인다
- 예상 계획(confirmed=false)으로 기록한 세션도 서버는 그대로 받는다. 서버는 연결 후 replay로 실제 결과를 다시 계산하고, 앱은 다음 pull·plan 조회로 새 계획을 받는다

## 서버 재계산 트리거 (A3)
- push/PUT으로 `program_instance_id`가 있는 세션이 끝났거나(`ended_at` 채워짐), 끝난 세션·그 세트가 바뀌거나 삭제되면 그 인스턴스를 같은 트랜잭션 끝에서 replay한다
- 같은 `(program_instance_id, plan_seq)`에 끝난 세션이 둘이면 먼저 끝난 것만 반영하고, 나중 것은 연결을 유지하되 replay에서 뺀다(오프라인 중복 시작 대비)
- FIXED_DATE 인스턴스는 plan 조회·replay 때 지난 예정일 중 세션도 skip도 없는 날을 `program_skip(auto=true)`로 채운다
