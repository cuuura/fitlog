package com.fitlog

import com.fitlog.core.AppJson
import com.fitlog.engine.Load
import com.fitlog.engine.ProgramDefinition
import com.fitlog.engine.Rule
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

/** 계약 템플릿 예시가 공용 모델로 읽히는지(트랙 리드 소유) */
class ModelParseTest {
    private fun load(name: String): ProgramDefinition =
        AppJson.decodeFromString(File("../contracts/v0.2/templates/$name").readText())

    @Test
    fun `contract templates parse into model`() {
        val sl = load("stronglifts-5x5.json")
        assertEquals(2, sl.days.size)
        assertIs<Rule.Linear>(sl.progression["squat"])
        assertIs<Load.Working>(sl.days[0].exercises[0].sets[0].load)

        val ns = load("nsuns-4day.json")
        assertEquals(4, ns.days.size)
        assertIs<Rule.AmrapTable>(ns.progression["bench"])
        assertEquals("deadlift", ns.lifts["sumo"]?.tmFrom)
    }

    @Test
    fun `model round trips`() {
        val sl = load("stronglifts-5x5.json")
        assertEquals(sl, AppJson.decodeFromString<ProgramDefinition>(AppJson.encodeToString(ProgramDefinition.serializer(), sl)))
    }
}
