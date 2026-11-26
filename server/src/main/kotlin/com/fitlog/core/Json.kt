package com.fitlog.core

import kotlinx.serialization.json.Json

val AppJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false   // null 필드는 응답에서 생략
    encodeDefaults = true
    isLenient = false
}
