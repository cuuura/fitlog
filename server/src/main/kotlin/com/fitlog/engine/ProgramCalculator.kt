package com.fitlog.engine

/**
 * 계산 엔진 공개 인터페이스 (engine.md). 구현: [ProgramEngine] (A2).
 * 모든 함수는 결정적이어야 한다(시각·난수 사용 금지).
 */
interface ProgramCalculator {
    /** 이 프로그램이 시작할 때 필요한 입력: 키 → TM 또는 WORKING (tmFrom·of 를 따라 실제 상태 키로 푼 결과) */
    fun requiredInputs(program: ProgramDefinition): Map<String, Needs>

    /** requiredInputs 중 시작 때 비워둘 수 있는 키(DOUBLE 규칙의 working) */
    fun optionalInputs(program: ProgramDefinition): Set<String> = emptySet()

    /** 사용자 입력으로 초기 상태를 만든다. 필요한 키가 빠지면 IllegalArgumentException(메시지에 키) */
    fun initialState(program: ProgramDefinition, tm: Map<String, Double>, working: Map<String, Double>): ProgramState

    /** 지금 상태에서 앞으로 count 회차. 첫 회차만 confirmed=true, 나머지는 모두 성공 가정 */
    fun plan(program: ProgramDefinition, state: ProgramState, count: Int, settings: EngineSettings = EngineSettings()): List<PlannedDay>

    fun apply(program: ProgramDefinition, state: ProgramState, event: ProgramEvent, settings: EngineSettings = EngineSettings()): ProgramState

    fun replay(program: ProgramDefinition, initial: ProgramState, events: List<ProgramEvent>, settings: EngineSettings = EngineSettings()): ProgramState =
        events.fold(initial) { s, e -> apply(program, s, e, settings) }

    /** engine.md 9절. 1RM 추정 불가(워밍업 제외는 호출자 몫, reps 0·>10, 무게 없음)면 null */
    fun estimateOneRm(formula: E1rmFormula, weightKg: Double?, reps: Int?): Double?

    /** engine.md 2절 반올림. barbell=true 면 barKg 미만은 barKg */
    fun roundWeight(kg: Double, roundingKg: Double, barKg: Double?, barbell: Boolean): Double
}
