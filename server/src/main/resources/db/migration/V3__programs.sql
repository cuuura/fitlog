-- v0.2 스키마 변경. 소유: A3. V2 = 기본 종목 시드.

-- [v0.1 보완] 종목 삭제/계정 삭제 시 세션 종목이 함께 지워지도록
ALTER TABLE session_exercise DROP CONSTRAINT session_exercise_exercise_id_fkey;
ALTER TABLE session_exercise ADD CONSTRAINT session_exercise_exercise_id_fkey
    FOREIGN KEY (exercise_id) REFERENCES exercise(id) ON DELETE CASCADE;

-- STA-6 1RM 추정식
ALTER TABLE user_settings ADD COLUMN e1rm_formula text NOT NULL DEFAULT 'EPLEY'
    CHECK (e1rm_formula IN ('EPLEY','BRZYCKI','LOMBARDI'));

-- PRG-1/2 프로그램 정의. owner_id NULL = 기본 템플릿
CREATE TABLE program (
    id              uuid PRIMARY KEY,
    owner_id        uuid REFERENCES app_user(id) ON DELETE CASCADE,
    template_key    text UNIQUE,                     -- 기본 템플릿만: 'stronglifts-5x5' 등
    name            text NOT NULL,
    definition      jsonb NOT NULL,                  -- program.schema.json, 이름 참조는 저장 전에 id로 바꿔 둔다
    source          text NOT NULL DEFAULT 'USER' CHECK (source IN ('TEMPLATE','USER','AI_JSON','AI_MCP')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz
);
CREATE INDEX program_owner_idx ON program(owner_id);

-- PRG-13 진행 중인 프로그램(인스턴스). 여러 개 동시 가능
CREATE TABLE program_instance (
    id              uuid PRIMARY KEY,
    user_id         uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    program_id      uuid NOT NULL REFERENCES program(id) ON DELETE CASCADE,
    definition      jsonb NOT NULL,                  -- 시작 시점 정의 스냅샷(원본 수정과 무관)
    status          text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','PAUSED','FINISHED')),
    skip_policy     text NOT NULL DEFAULT 'SHIFT' CHECK (skip_policy IN ('SHIFT','FIXED_DATE')),
    start_date      date NOT NULL,
    tz              text NOT NULL,
    initial_state   jsonb NOT NULL,                  -- engine.md State (초기 tm/working)
    state           jsonb NOT NULL,                  -- replay 결과 캐시
    state_seq       integer NOT NULL DEFAULT 0,      -- 캐시가 반영한 회차 수
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz
);
CREATE INDEX program_instance_user_idx ON program_instance(user_id, status);

-- PRG-6 건너뛰기 기록(SHIFT도 명시적으로 남김, FIXED_DATE 지난 예정일은 서버가 자동 생성)
CREATE TABLE program_skip (
    id              uuid PRIMARY KEY,
    instance_id     uuid NOT NULL REFERENCES program_instance(id) ON DELETE CASCADE,
    plan_seq        integer NOT NULL,
    day_index       integer NOT NULL,
    skipped_on      date NOT NULL,
    auto            boolean NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (instance_id, plan_seq)
);

-- PRG-8 인스턴스에 붙인 보조운동(계속 반복). 한 번만 하는 보조운동은 세션에 바로 추가
CREATE TABLE program_accessory (
    id              uuid PRIMARY KEY,
    instance_id     uuid NOT NULL REFERENCES program_instance(id) ON DELETE CASCADE,
    day_key         text NOT NULL,
    exercise_id     uuid NOT NULL REFERENCES exercise(id) ON DELETE CASCADE,
    position        integer NOT NULL,
    sets            integer NOT NULL CHECK (sets BETWEEN 1 AND 20),
    reps            integer NOT NULL CHECK (reps BETWEEN 0 AND 100),
    weight_kg       numeric(6,2),                    -- NULL이면 지난 기록 무게를 앱이 채움
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz
);
CREATE INDEX program_accessory_instance_idx ON program_accessory(instance_id, day_key, position);

-- 세션과 계획 연결 (sync payload에 포함)
ALTER TABLE workout_session ADD COLUMN program_instance_id uuid REFERENCES program_instance(id) ON DELETE SET NULL;
ALTER TABLE workout_session ADD COLUMN plan_seq   integer;
ALTER TABLE workout_session ADD COLUMN plan_day_key text;
CREATE UNIQUE INDEX session_instance_seq_uq ON workout_session(program_instance_id, plan_seq)
    WHERE program_instance_id IS NOT NULL AND deleted_at IS NULL;

ALTER TABLE session_exercise ADD COLUMN lift_key text;          -- 프로그램 종목이면 lifts 키
ALTER TABLE session_exercise ADD COLUMN accessory boolean NOT NULL DEFAULT false;

ALTER TABLE workout_set ADD COLUMN planned_set_key  text;       -- engine.md "D1.0.2"
ALTER TABLE workout_set ADD COLUMN target_reps      integer CHECK (target_reps >= 0);
ALTER TABLE workout_set ADD COLUMN target_weight_kg numeric(6,2);
ALTER TABLE workout_set ADD COLUMN is_amrap         boolean NOT NULL DEFAULT false;

-- STA-2 직접 측정 1RM (REST 전용, 동기화 대상 아님)
CREATE TABLE one_rm_measurement (
    id              uuid PRIMARY KEY,
    user_id         uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    exercise_id     uuid NOT NULL REFERENCES exercise(id) ON DELETE CASCADE,
    weight_kg       numeric(6,2) NOT NULL CHECK (weight_kg > 0),
    measured_at     timestamptz NOT NULL,
    note            text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz
);
CREATE INDEX one_rm_user_ex_idx ON one_rm_measurement(user_id, exercise_id, measured_at DESC);

-- PATCH adjust(TM·작업 무게 직접 조정) 이벤트. replay에서 seq 위치에 끼워 넣음
CREATE TABLE program_adjustment (
    id              uuid PRIMARY KEY,
    instance_id     uuid NOT NULL REFERENCES program_instance(id) ON DELETE CASCADE,
    after_seq       integer NOT NULL,                -- 이 회차 수 뒤에 적용
    tm              jsonb NOT NULL DEFAULT '{}',
    working         jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX program_adjustment_instance_idx ON program_adjustment(instance_id, after_seq, created_at);
