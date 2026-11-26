package com.fitlog.fitlog

import android.content.Intent
import android.net.Uri
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.StandardIntegrityManager
import com.google.android.play.core.integrity.StandardIntegrityManager.PrepareIntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenProvider
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 채널 `fitlog/integrity`: Play Integrity Standard API(contracts/v1.0/security.md).
 *  - prepare(cloudProjectNumber: String) -> true. 토큰 제공자를 준비한다.
 *  - request(requestHash: String) -> 토큰 문자열. prepare가 안 됐으면 PREPARE_REQUIRED.
 * 채널 `fitlog/links`: openUrl(url: String) -> 외부 브라우저로 연다(http/https만).
 * 모든 실패는 result.error로 돌려주고 Dart가 null(헤더 없음)로 처리한다.
 */
class MainActivity : FlutterActivity() {
    @Volatile
    private var tokenProvider: StandardIntegrityTokenProvider? = null

    private val integrityManager: StandardIntegrityManager by lazy {
        IntegrityManagerFactory.createStandard(applicationContext)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "fitlog/integrity").setMethodCallHandler { call, result ->
            onIntegrityCall(call, result)
        }
        MethodChannel(messenger, "fitlog/links").setMethodCallHandler { call, result ->
            onLinksCall(call, result)
        }
    }

    private fun onIntegrityCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepare" -> {
                val number = call.argument<String>("cloudProjectNumber")?.toLongOrNull()
                if (number == null) {
                    result.error("BAD_ARGUMENT", "cloudProjectNumber must be numeric", null)
                    return
                }
                try {
                    integrityManager
                        .prepareIntegrityToken(
                            PrepareIntegrityTokenRequest.builder().setCloudProjectNumber(number).build()
                        )
                        .addOnSuccessListener { provider ->
                            tokenProvider = provider
                            result.success(true)
                        }
                        .addOnFailureListener { e -> result.error("PREPARE_FAILED", e.message, null) }
                } catch (e: Exception) {
                    result.error("PREPARE_FAILED", e.message, null)
                }
            }
            "request" -> {
                val hash = call.argument<String>("requestHash")
                val provider = tokenProvider
                if (hash.isNullOrEmpty()) {
                    result.error("BAD_ARGUMENT", "requestHash is required", null)
                    return
                }
                if (provider == null) {
                    result.error("PREPARE_REQUIRED", "prepare was not completed", null)
                    return
                }
                try {
                    provider
                        .request(StandardIntegrityTokenRequest.builder().setRequestHash(hash).build())
                        .addOnSuccessListener { response -> result.success(response.token()) }
                        .addOnFailureListener { e -> result.error("REQUEST_FAILED", e.message, null) }
                } catch (e: Exception) {
                    result.error("REQUEST_FAILED", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun onLinksCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "openUrl") {
            result.notImplemented()
            return
        }
        val uri = call.argument<String>("url")?.let { Uri.parse(it) }
        if (uri == null || (uri.scheme != "https" && uri.scheme != "http")) {
            result.success(false)
            return
        }
        try {
            startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            result.success(true)
        } catch (e: Exception) {
            result.success(false)
        }
    }
}
