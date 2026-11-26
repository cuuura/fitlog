package com.fitlog.program.catalog

import com.fitlog.core.Exercises
import com.fitlog.core.dbQuery
import com.fitlog.engine.ExerciseRef
import com.fitlog.program.schema.ExerciseResolver
import com.fitlog.program.schema.ProgramValidator
import com.fitlog.program.schema.ResolveResult
import org.jetbrains.exposed.sql.Op
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.SqlExpressionBuilder.isNull
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.or
import org.jetbrains.exposed.sql.selectAll
import java.util.UUID

/** 검증기에 넘길 종목 참조 풀이. 보이는 종목(기본 + 그 사용자 것, 삭제 안 됨)을 한 번 읽어 메모리에서 푼다 */
class ExerciseIndex(private val rows: List<Row>) {
    data class Row(val id: String, val ownerId: UUID?, val nameKo: String, val nameEn: String?)

    private val ids = rows.map { it.id }.toSet()

    val resolver: ExerciseResolver = { ref -> resolve(ref) }

    fun resolve(ref: ExerciseRef): ResolveResult {
        val id = ref.id
        if (id != null) {
            return if (id.lowercase() in ids) ResolveResult.Found(id.lowercase())
            else ResolveResult.Failed("exercise '$id' does not exist")
        }
        val name = ref.name ?: return ResolveResult.Failed("exercise reference is empty")
        val key = ProgramValidator.normalizeName(name)
        val matches = rows.filter {
            ProgramValidator.normalizeName(it.nameKo) == key ||
                (it.nameEn != null && ProgramValidator.normalizeName(it.nameEn) == key)
        }
        if (matches.isEmpty()) return ResolveResult.Failed("no exercise named '$name'")
        // 내 종목 우선, 같은 쪽에서 둘 이상이면 모호
        val mine = matches.filter { it.ownerId != null }.map { it.id }.distinct()
        if (mine.size == 1) return ResolveResult.Found(mine[0])
        if (mine.size > 1) return ResolveResult.Failed("exercise name '$name' is ambiguous (${mine.size} of your exercises match)")
        val builtIn = matches.map { it.id }.distinct()
        return if (builtIn.size == 1) ResolveResult.Found(builtIn[0])
        else ResolveResult.Failed("exercise name '$name' is ambiguous (${builtIn.size} exercises match)")
    }

    companion object {
        /** userId 가 null 이면 기본 종목만 */
        suspend fun load(userId: UUID?): ExerciseIndex = dbQuery { loadInTx(userId) }

        /** 이미 열린 트랜잭션 안에서 */
        fun loadInTx(userId: UUID?): ExerciseIndex {
            val visible: Op<Boolean> =
                if (userId == null) Exercises.ownerId.isNull() else (Exercises.ownerId.isNull() or (Exercises.ownerId eq userId))
            val rows = Exercises.selectAll().where { Exercises.deletedAt.isNull() and visible }.map {
                Row(it[Exercises.id].toString(), it[Exercises.ownerId], it[Exercises.nameKo], it[Exercises.nameEn])
            }
            return ExerciseIndex(rows)
        }
    }
}
