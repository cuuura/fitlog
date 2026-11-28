package com.fitlog.ops

import com.fitlog.core.AppConfig
import io.ktor.server.application.Application
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration

/**
 * Render 무료 플랜은 15분간 외부 요청이 없으면 잠든다. 서버가 자기 공개 주소의 /health 를
 * 주기적으로 호출해 Render 엣지에 인바운드 트래픽으로 보이게 한다. selfPingUrl 이 null 이면 아무것도 하지 않는다.
 */
fun Application.installSelfPing(config: AppConfig) {
    val base = config.selfPingUrl ?: return
    val intervalSec = config.selfPingIntervalSec
    val log = environment.log
    log.info("self-ping enabled: $base every ${intervalSec}s")
    val client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10)).build()
    val request = HttpRequest.newBuilder(URI.create("$base/health")).timeout(Duration.ofSeconds(30)).GET().build()
    launch(Dispatchers.IO) {
        delay(60_000)
        while (true) {
            try {
                val res = client.send(request, HttpResponse.BodyHandlers.discarding())
                if (res.statusCode() in 200..299) log.debug("self-ping ok: ${res.statusCode()}")
                else log.warn("self-ping got HTTP ${res.statusCode()} from $base/health")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log.warn("self-ping failed: ${e.message}")
            }
            delay(intervalSec * 1000)
        }
    }
}
