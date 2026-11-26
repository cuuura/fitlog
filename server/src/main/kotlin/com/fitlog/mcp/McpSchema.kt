package com.fitlog.mcp

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** JSON Schema 조각을 짧게 쓰기 위한 도구 (도구 inputSchema·outputSchema 용) */
internal object S {
    fun str(desc: String? = null, enum: List<String>? = null, format: String? = null): JsonObject = buildJsonObject {
        put("type", "string")
        desc?.let { put("description", it) }
        format?.let { put("format", it) }
        enum?.let { put("enum", JsonArray(it.map(::JsonPrimitive))) }
    }

    fun int(desc: String? = null, min: Int? = null, max: Int? = null): JsonObject = buildJsonObject {
        put("type", "integer")
        desc?.let { put("description", it) }
        min?.let { put("minimum", it) }
        max?.let { put("maximum", it) }
    }

    fun num(desc: String? = null, min: Double? = null, max: Double? = null): JsonObject = buildJsonObject {
        put("type", "number")
        desc?.let { put("description", it) }
        min?.let { put("minimum", it) }
        max?.let { put("maximum", it) }
    }

    fun bool(desc: String? = null): JsonObject = buildJsonObject {
        put("type", "boolean")
        desc?.let { put("description", it) }
    }

    fun arr(items: JsonElement, desc: String? = null): JsonObject = buildJsonObject {
        put("type", "array")
        put("items", items)
        desc?.let { put("description", it) }
    }

    /** 키가 자유로운 객체. values 는 값 스키마 */
    fun map(values: JsonElement, desc: String? = null): JsonObject = buildJsonObject {
        put("type", "object")
        put("additionalProperties", values)
        desc?.let { put("description", it) }
    }

    /** 구조를 이 스키마 밖(공개 JSON 스키마)에서 정의하는 객체 */
    fun anyObj(desc: String? = null): JsonObject = buildJsonObject {
        put("type", "object")
        desc?.let { put("description", it) }
    }

    fun obj(vararg props: Pair<String, JsonElement>, required: List<String> = emptyList(), desc: String? = null): JsonObject =
        buildJsonObject {
            put("type", "object")
            desc?.let { put("description", it) }
            put("properties", JsonObject(props.toMap()))
            if (required.isNotEmpty()) put("required", JsonArray(required.map(::JsonPrimitive)))
        }
}
