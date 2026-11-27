package com.fitlog.program.catalog

import com.fitlog.core.AppJson
import com.fitlog.core.Programs
import com.fitlog.core.Times
import com.fitlog.engine.ProgramDefinition
import com.fitlog.program.schema.ProgramValidator
import com.fitlog.program.schema.orThrow
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.transactions.transaction
import org.jetbrains.exposed.sql.update
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/** 기본 템플릿 20종. 순서·id 는 고정이다(앱·인스턴스가 참조). 새 템플릿은 뒤에 추가 */
object ProgramTemplates {
    data class Template(val key: String, val id: UUID)

    private fun tid(n: Int) = UUID.fromString("019b76da-5000-7000-8000-%012x".format(n))

    val all: List<Template> = listOf(
        Template("stronglifts-5x5", tid(1)),
        Template("nsuns-4day", tid(2)),
        Template("wendler-531-bbb", tid(3)),
        Template("gzclp", tid(4)),
        Template("texas-method", tid(5)),
        Template("nsuns-5day", tid(6)),
        Template("nsuns-6day", tid(7)),
        Template("wendler-531-bbs", tid(8)),
        Template("wendler-531-fsl", tid(9)),
        Template("wendler-531-beginners", tid(10)),
        Template("novice-3x5-ab", tid(11)),
        Template("greyskull-lp", tid(12)),
        Template("madcow-5x5", tid(13)),
        Template("reddit-ppl-6day", tid(14)),
        Template("ppl-3day", tid(15)),
        Template("upper-lower-4day", tid(16)),
        Template("phul-4day", tid(17)),
        Template("fullbody-3day-beginner", tid(18)),
        Template("dumbbell-home-3day", tid(19)),
        Template("rippler-12week", tid(20)),
    )

    fun idOf(key: String): UUID = all.first { it.key == key }.id

    fun readJson(key: String) = Json.parseToJsonElement(
        (ProgramTemplates::class.java.getResourceAsStream("/programs/$key.json")
            ?: error("missing template resource programs/$key.json")).use { it.readBytes().toString(Charsets.UTF_8) },
    )

    private val seeded = AtomicBoolean(false)

    /** programRoutes 가 프로세스당 한 번 부른다. 이미 했으면 아무것도 안 한다 */
    fun seedOnce() {
        if (seeded.compareAndSet(false, true)) {
            try {
                seedProgramTemplates()
            } catch (e: Throwable) {
                seeded.set(false)
                throw e
            }
        }
    }
}

/**
 * 템플릿을 program 테이블에 upsert 한다(owner NULL, template_key=파일 이름, source TEMPLATE, 고정 id).
 * Flyway 가 끝난 뒤에 불러야 한다. 여러 번 불러도 안전하다.
 */
fun seedProgramTemplates() {
    transaction {
        val index = ExerciseIndex.loadInTx(null)
        for (t in ProgramTemplates.all) {
            val def: ProgramDefinition = ProgramValidator.validate(ProgramTemplates.readJson(t.key), index.resolver).orThrow()
            val text = AppJson.encodeToString(def)
            val now = Times.now()
            val updated = Programs.update({ Programs.id eq t.id }) {
                it[name] = def.name
                it[definition] = text
                it[templateKey] = t.key
                it[ownerId] = null
                it[sourceCol] = "TEMPLATE"
                it[updatedAt] = now
                it[deletedAt] = null
            }
            if (updated == 0) {
                val exists = Programs.selectAll().where { Programs.templateKey eq t.key }.any()
                if (!exists) {
                    Programs.insert {
                        it[id] = t.id
                        it[ownerId] = null
                        it[templateKey] = t.key
                        it[name] = def.name
                        it[definition] = text
                        it[sourceCol] = "TEMPLATE"
                        it[createdAt] = now
                        it[updatedAt] = now
                    }
                }
            }
        }
    }
}
