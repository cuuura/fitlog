-- v0.1 초기 스키마. 소유: A2. 이후 버전 확장(트레이너, 프로그램)을 막지 않도록 설계.
-- 모든 id는 UUIDv7 (클라이언트 생성 허용).

CREATE TABLE app_user (
    id              uuid PRIMARY KEY,
    google_sub      text NOT NULL UNIQUE,
    email           text NOT NULL,
    display_name    text,
    role            text NOT NULL DEFAULT 'MEMBER' CHECK (role IN ('MEMBER','TRAINER')), -- TRAINER는 v2.0
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE refresh_token (
    id              uuid PRIMARY KEY,
    user_id         uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    token_hash      text NOT NULL UNIQUE,
    expires_at      timestamptz NOT NULL,
    revoked_at      timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- ACC-6 동의 이력 (버전별 기록)
CREATE TABLE consent (
    id              uuid PRIMARY KEY,
    user_id         uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    kind            text NOT NULL CHECK (kind IN ('TERMS','PRIVACY','HEALTH_DATA')),
    version         text NOT NULL,
    granted         boolean NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX consent_user_idx ON consent(user_id, kind, created_at DESC);

-- ACC-3 설정, BDY-5 프로필
CREATE TABLE user_settings (
    user_id                 uuid PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
    weight_unit             text NOT NULL DEFAULT 'KG' CHECK (weight_unit IN ('KG','LB')),
    default_rest_sec        integer NOT NULL DEFAULT 120 CHECK (default_rest_sec BETWEEN 0 AND 3600),
    keep_screen_on          boolean NOT NULL DEFAULT true,
    rpe_input_enabled       boolean NOT NULL DEFAULT true,
    height_cm               numeric(5,1),
    sex                     text CHECK (sex IN ('MALE','FEMALE','OTHER')),
    birth_year              integer CHECK (birth_year BETWEEN 1900 AND 2100),
    updated_at              timestamptz NOT NULL DEFAULT now()
);

-- EXR-1/2 종목. owner_id NULL = 기본 제공 종목
CREATE TABLE exercise (
    id              uuid PRIMARY KEY,
    owner_id        uuid REFERENCES app_user(id) ON DELETE CASCADE,
    name_ko         text NOT NULL,
    name_en         text,
    type            text NOT NULL CHECK (type IN ('BARBELL','DUMBBELL','MACHINE','BODYWEIGHT','BAND','CARDIO')),
    primary_muscle  text NOT NULL,          -- muscle 코드 (아래 enum 참고)
    secondary_muscles text[] NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz
);
CREATE INDEX exercise_owner_idx ON exercise(owner_id);
-- muscle 코드: CHEST, BACK, LATS, TRAPS, SHOULDERS, REAR_DELTS, BICEPS, TRICEPS, FOREARMS,
--             QUADS, HAMSTRINGS, GLUTES, CALVES, ADDUCTORS, ABS, OBLIQUES, LOWER_BACK, FULL_BODY, CARDIO

-- LOG-1/7 세션. program_id 등은 v0.2에서 추가
CREATE TABLE workout_session (
    id              uuid PRIMARY KEY,
    user_id         uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    started_at      timestamptz NOT NULL,
    ended_at        timestamptz,
    tz              text NOT NULL,
    note            text,
    source          text NOT NULL DEFAULT 'APP' CHECK (source IN ('APP','AI_JSON','AI_MCP','IMPORT')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz
);
CREATE INDEX session_user_started_idx ON workout_session(user_id, started_at DESC);
CREATE INDEX session_user_updated_idx ON workout_session(user_id, updated_at);

-- 세션 안의 종목 순서
CREATE TABLE session_exercise (
    id              uuid PRIMARY KEY,
    session_id      uuid NOT NULL REFERENCES workout_session(id) ON DELETE CASCADE,
    exercise_id     uuid NOT NULL REFERENCES exercise(id),
    position        integer NOT NULL,
    note            text,
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz
);
CREATE INDEX session_exercise_session_idx ON session_exercise(session_id, position);

-- LOG-2 세트
CREATE TABLE workout_set (
    id                  uuid PRIMARY KEY,
    session_exercise_id uuid NOT NULL REFERENCES session_exercise(id) ON DELETE CASCADE,
    position            integer NOT NULL,
    is_warmup           boolean NOT NULL DEFAULT false,
    weight_kg           numeric(6,2),       -- DUMBBELL은 한쪽 무게
    added_weight_kg     numeric(6,2),       -- BODYWEIGHT 추가(음수=보조)
    reps                integer CHECK (reps >= 0),
    duration_sec        integer CHECK (duration_sec >= 0),
    distance_m          numeric(8,1),
    band_level          text,
    rpe                 numeric(3,1) CHECK (rpe BETWEEN 1 AND 10),
    rir                 integer CHECK (rir BETWEEN 0 AND 10),
    rest_sec            integer CHECK (rest_sec >= 0), -- 이 세트 뒤 실제 휴식
    note                text,
    completed_at        timestamptz,
    updated_at          timestamptz NOT NULL DEFAULT now(),
    deleted_at          timestamptz
);
CREATE INDEX workout_set_se_idx ON workout_set(session_exercise_id, position);

-- BDY-1 체중 (BDY-2 신체 수치는 v1.1에서 컬럼/테이블 추가)
CREATE TABLE body_measurement (
    id              uuid PRIMARY KEY,
    user_id         uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    measured_at     timestamptz NOT NULL,
    weight_kg       numeric(5,2) NOT NULL,
    source          text NOT NULL DEFAULT 'MANUAL' CHECK (source IN ('MANUAL','HEALTH_CONNECT','HEALTHKIT','OCR')),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz
);
CREATE INDEX body_user_measured_idx ON body_measurement(user_id, measured_at DESC);

-- LOG-8 동기화: 서버 변경 순번
CREATE SEQUENCE change_seq;
ALTER TABLE workout_session  ADD COLUMN server_seq bigint NOT NULL DEFAULT nextval('change_seq');
ALTER TABLE session_exercise ADD COLUMN server_seq bigint NOT NULL DEFAULT nextval('change_seq');
ALTER TABLE workout_set      ADD COLUMN server_seq bigint NOT NULL DEFAULT nextval('change_seq');
ALTER TABLE body_measurement ADD COLUMN server_seq bigint NOT NULL DEFAULT nextval('change_seq');
ALTER TABLE exercise         ADD COLUMN server_seq bigint NOT NULL DEFAULT nextval('change_seq');
-- 행을 갱신할 때마다 server_seq = nextval('change_seq') 로 다시 매긴다 (서버 코드 책임)
