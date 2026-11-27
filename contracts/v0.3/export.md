# 내보내기 (A3 소유, DAT-1·DAT-2)

## JSON (`GET /v1/export.json`)
- **가져오기 묶음 형식 그대로**(`import.schema.json`, `schemaVersion: 1`)에 `exportedAt`, `app: "fitlog"`를 `note`에 적는다
- 내 종목 전부, 내 프로그램 전부(템플릿 제외), 진행 중·일시정지 인스턴스(`startPrograms`, 현재 상태가 아니라 **초기값**과 시작일), 세션 전부(삭제 제외, `program` 연결 포함), 체중 전부. 모든 id 유지
- 종목 참조는 기본 종목이면 `{ "id": ... }`(고정 id라 다른 계정에서도 같음), 내 종목도 `{ "id": ... }`이고 `exercises[]`에 함께 담긴다
- 새 계정에 가져오면 같은 기록이 되어야 한다(완료 기준 5). 인스턴스 상태는 가져온 세션으로 replay되어 같은 값이 된다
- 묶음 한도(세션 200 등)는 내보내기에는 적용하지 않는다. 가져오기 쪽에서 큰 파일은 앱이 200세션 단위로 나눠 보낸다(B1)

## CSV (`GET /v1/export.csv?kind=sets|body`)
UTF-8 BOM, 쉼표 구분, 첫 줄 헤더, 날짜는 사용자 시간대 현지 시각 `YYYY-MM-DD HH:mm`.

`kind=sets` (세트 한 줄):
```
date,session_id,program,day,exercise_ko,exercise_en,exercise_type,set_no,is_warmup,weight_kg,added_weight_kg,reps,rpe,rir,rest_sec,duration_sec,distance_m,target_reps,target_weight_kg,is_amrap,note
```
`kind=body`:
```
date,weight_kg,source
```
- 덤벨 `weight_kg`는 한쪽 무게(헤더 그대로). 빈 값은 빈 칸
- Strong·Hevy 가져오기(DAT-3)는 v1.2

> v1.0 추가: JSON에 `scheduledWorkouts`와 세션 `scheduledWorkoutId`. `../v1.0/scheduled-workout.md` §8.
