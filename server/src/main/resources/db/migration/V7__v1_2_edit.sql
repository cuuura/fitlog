-- v1.2 편집·확장. 계약 contracts/v1.2/. 서버 리드가 server/src/main/resources/db/migration 에 그대로 복사.
-- (로드맵에서 V7 로 잡혀 있던 신체·근력 수치 A4 는 V8 이후로 밀린다)

-- LOG-9 슈퍼세트·드롭세트
ALTER TABLE session_exercise ADD COLUMN superset_group text
    CHECK (superset_group IS NULL OR char_length(superset_group) BETWEEN 1 AND 8);
ALTER TABLE workout_set ADD COLUMN set_type text NOT NULL DEFAULT 'NORMAL'
    CHECK (set_type IN ('NORMAL','DROP','FAILURE'));

-- PRG-2 진행 중 프로그램 정의 교체(다음 회차부터 적용). base_seq 이하 회차는 replay 하지 않는다
ALTER TABLE program_instance ADD COLUMN base_seq integer NOT NULL DEFAULT 0;
-- 바꾼 운동 순서 기억: {"<dayKey>": [정의상 종목 인덱스 순열]}
ALTER TABLE program_instance ADD COLUMN day_order jsonb NOT NULL DEFAULT '{}'::jsonb;
-- 교체 시점의 마지막 이벤트 날짜(FIXED_DATE 예정일 기준). 교체한 적 없으면 NULL
ALTER TABLE program_instance ADD COLUMN base_date date;
