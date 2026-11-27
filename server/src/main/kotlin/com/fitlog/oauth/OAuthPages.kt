package com.fitlog.oauth

/** 로그인·동의 웹 페이지 (서버가 그리는 HTML). 사용자 입력은 모두 escape 한다 */
internal object OAuthPages {
    fun esc(s: String): String = buildString {
        for (c in s) when (c) {
            '&' -> append("&amp;")
            '<' -> append("&lt;")
            '>' -> append("&gt;")
            '"' -> append("&quot;")
            '\'' -> append("&#39;")
            else -> append(c)
        }
    }

    private fun page(title: String, body: String) = """<!doctype html>
<html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title>
<style>
body{font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:#f4f5f7;margin:0;color:#1c1e21}
main{max-width:420px;margin:8vh auto;background:#fff;padding:28px 24px;border-radius:14px;box-shadow:0 2px 12px rgba(0,0,0,.08)}
h1{font-size:20px;margin:0 0 16px}
p{line-height:1.55;margin:8px 0}
.muted{color:#666;font-size:13px}
label.opt{display:flex;gap:10px;align-items:flex-start;margin:14px 0;padding:12px;border:1px solid #d8dbe0;border-radius:10px}
input[type=text],input[type=password]{width:100%;box-sizing:border-box;padding:11px;margin:4px 0 12px;border:1px solid #c5c9d0;border-radius:10px;font-size:15px}
.err{color:#b3261e;background:#fdecea;border-radius:8px;padding:10px 12px}
a.btn{display:block;text-align:center;padding:12px;border-radius:10px;border:1px solid #c5c9d0;color:#1c1e21;text-decoration:none;margin-top:14px}
.btns{display:flex;gap:10px;margin-top:20px}
button{flex:1;padding:12px;border-radius:10px;border:1px solid #c5c9d0;background:#fff;font-size:15px;cursor:pointer}
button.primary{background:#1a73e8;color:#fff;border-color:#1a73e8}
</style></head><body><main>$body</main></body></html>"""

    fun error(title: String, message: String) =
        page(title, "<h1>${esc(title)}</h1><p>${esc(message)}</p><p class=\"muted\">이 창을 닫고 AI 앱에서 다시 시도해 주세요.</p>")

    fun login(clientName: String, formToken: String, action: String, googleUrl: String?, errorMessage: String? = null): String {
        val err = if (errorMessage != null) "<p class=\"err\" role=\"alert\">${esc(errorMessage)}</p>" else ""
        val google = if (googleUrl != null) "<a class=\"btn\" href=\"${esc(googleUrl)}\">Google로 계속하기</a>" else ""
        return page(
            "로그인",
            """<h1>${esc(clientName)} 연결을 위해 로그인</h1>
<p class="muted">Fitlog 앱에서 쓰는 아이디·비밀번호로 로그인해 주세요.</p>
$err
<form method="post" action="${esc(action)}">
<input type="hidden" name="authz" value="${esc(formToken)}">
<label>아이디<input type="text" name="username" autocomplete="username" autocapitalize="none" required></label>
<label>비밀번호<input type="password" name="password" autocomplete="current-password" required></label>
<div class="btns"><button type="submit" class="primary">로그인</button></div>
</form>
$google""",
        )
    }

    fun consent(clientName: String, email: String, canWrite: Boolean, formToken: String, action: String): String {
        val writeBox = if (canWrite) {
            """<label class="opt"><input type="checkbox" name="write" value="1" checked>
<span><b>기록 추가·수정 허용</b><br><span class="muted">프로그램 만들기, 운동·체중 기록 추가, 삭제 요청 만들기. 삭제는 앱에서 직접 승인해야 실행됩니다.</span></span></label>"""
        } else ""
        return page(
            "연결 허용",
            """<h1>${esc(clientName)}이(가) 내 운동 기록을 ${if (canWrite) "읽고/추가합니다" else "읽습니다"}</h1>
<p class="muted">${esc(email)} 계정으로 로그인됨</p>
<form method="post" action="${esc(action)}">
<input type="hidden" name="form" value="${esc(formToken)}">
<label class="opt"><input type="checkbox" checked disabled>
<span><b>운동 기록 읽기</b><br><span class="muted">세션, 프로그램, 기록(PR), 체중</span></span></label>
<!-- 쓰기 체크박스는 반드시 form 안에 있어야 제출된다(밖에 있으면 모든 연결이 읽기 전용이 됨) -->
$writeBox
<div class="btns">
<button type="submit" name="decision" value="deny">거부</button>
<button type="submit" name="decision" value="allow" class="primary">허용</button>
</div></form>
<p class="muted">언제든 Fitlog 앱의 AI 연결에서 연결을 끊을 수 있습니다.</p>""",
        )
    }
}
