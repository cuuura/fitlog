package com.fitlog.core

import org.jetbrains.exposed.sql.Column
import org.jetbrains.exposed.sql.ColumnType
import org.jetbrains.exposed.sql.Table
import org.postgresql.util.PGobject

/** jsonb 컬럼을 JSON 문자열로 읽고 쓴다. (역)직렬화는 호출자가 AppJson 으로 한다 */
class JsonbTextColumnType : ColumnType<String>() {
    override fun sqlType(): String = "jsonb"
    override fun valueFromDB(value: Any): String = when (value) {
        is PGobject -> value.value ?: "null"
        else -> value.toString()
    }
    override fun notNullValueToDB(value: String): Any = PGobject().apply {
        type = "jsonb"
        this.value = value
    }
    override fun nonNullValueToString(value: String): String = "'" + value.replace("'", "''") + "'::jsonb"
}

fun Table.jsonbText(name: String): Column<String> = registerColumn(name, JsonbTextColumnType())
