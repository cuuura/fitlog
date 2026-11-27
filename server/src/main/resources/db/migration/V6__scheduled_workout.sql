-- v1.0 추가: LOG-13 하루짜리 예정 운동. 계약 scheduled-workout.md. 서버 A(SW-A)가 server/src/main/resources/db/migration 에 그대로 복사.

CREATE TABLE scheduled_workout (
    id              uuid PRIMARY KEY,
    user_id         uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    planned_date    date NOT NULL,                       -- 사용자 현지 날짜
    title           text NOT NULL CHECK (char_length(title) BETWEEN 1 AND 100),
    note            text,
    items           jsonb NOT NULL,                      -- ScheduledItem[] (scheduled-workout.md §2), exerciseId 로 풀린 상태
    skipped_at      timestamptz,
    source          text NOT NULL DEFAULT 'APP' CHECK (source IN ('APP','AI_JSON','AI_MCP','IMPORT')),
    import_batch_id uuid REFERENCES import_batch(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz,
    server_seq      bigint NOT NULL DEFAULT nextval('change_seq')
);
CREATE INDEX scheduled_workout_user_date_idx ON scheduled_workout(user_id, planned_date);
CREATE INDEX scheduled_workout_user_seq_idx  ON scheduled_workout(user_id, server_seq);

-- 세션 ↔ 예정 운동. 예정 하나에 살아 있는 세션은 하나
ALTER TABLE workout_session ADD COLUMN scheduled_workout_id uuid REFERENCES scheduled_workout(id) ON DELETE SET NULL;
CREATE UNIQUE INDEX session_scheduled_uq ON workout_session(scheduled_workout_id)
    WHERE scheduled_workout_id IS NOT NULL AND deleted_at IS NULL;

-- 세트 목표 확장 (예정 운동에서 복사. 프로그램 세트는 비워 둠)
ALTER TABLE workout_set ADD COLUMN target_reps_max integer CHECK (target_reps_max >= 0);
ALTER TABLE workout_set ADD COLUMN target_rir      integer CHECK (target_rir BETWEEN 0 AND 10);
ALTER TABLE workout_set ADD COLUMN target_rest_sec integer CHECK (target_rest_sec BETWEEN 0 AND 3600);

-- 가져오기 항목·삭제 요청 대상에 추가
ALTER TABLE import_item DROP CONSTRAINT import_item_entity_check;
ALTER TABLE import_item ADD CONSTRAINT import_item_entity_check
    CHECK (entity IN ('exercise','program','program_instance','workout_session','body_measurement','scheduled_workout'));
ALTER TABLE deletion_request DROP CONSTRAINT deletion_request_entity_check;
ALTER TABLE deletion_request ADD CONSTRAINT deletion_request_entity_check
    CHECK (entity IN ('workout_session','program','program_instance','exercise','body_measurement','scheduled_workout'));
