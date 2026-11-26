package com.fitlog.engine

/** A2 소유. engine.md 규칙 구현 */
object ProgramEngine : ProgramCalculator {
    override fun requiredInputs(program: ProgramDefinition): Map<String, Needs> = TODO("A2")
    override fun initialState(program: ProgramDefinition, tm: Map<String, Double>, working: Map<String, Double>): ProgramState = TODO("A2")
    override fun plan(program: ProgramDefinition, state: ProgramState, count: Int, settings: EngineSettings): List<PlannedDay> = TODO("A2")
    override fun apply(program: ProgramDefinition, state: ProgramState, event: ProgramEvent, settings: EngineSettings): ProgramState = TODO("A2")
    override fun estimateOneRm(formula: E1rmFormula, weightKg: Double?, reps: Int?): Double? = TODO("A2")
    override fun roundWeight(kg: Double, roundingKg: Double, barKg: Double?, barbell: Boolean): Double = TODO("A2")
}
