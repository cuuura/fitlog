package com.fitlog.ops

import com.fitlog.core.AppConfig

/** 공개 HTML 페이지 조립. 개인정보 처리방침은 계약 md 를 jar 에서 읽어 렌더링한다 */
object SitePages {
    private const val POLICY_RESOURCE = "site/privacy-policy.md"

    fun privacy(config: AppConfig): String {
        val md = SitePages::class.java.classLoader.getResourceAsStream(POLICY_RESOURCE)
            ?.use { it.readBytes().toString(Charsets.UTF_8) }
            ?: error("$POLICY_RESOURCE not found on classpath")
        val filled = md
            .replace("{{CONTACT_EMAIL}}", config.site.contactEmail)
            .replace("{{EFFECTIVE_DATE}}", config.site.effectiveDate)
            .replace("{{BACKUP_RETENTION_DAYS}}", config.site.backupRetentionDays.toString())
            .replace("{{BASE_URL}}", config.publicBaseUrl)
        return page("fitlog 개인정보 처리방침", Markdown.render(filled))
    }

    fun accountDeletion(config: AppConfig): String {
        val mail = Markdown.escape(config.site.contactEmail)
        val days = config.site.backupRetentionDays
        val body = """
<h1>fitlog 계정 삭제 안내</h1>
<p>앱 이름: <strong>fitlog</strong> (운동 기록·프로그램 무게 계산 앱)</p>

<h2>앱에서 삭제하기</h2>
<ol>
<li>fitlog 앱을 열고 로그인합니다.</li>
<li><strong>설정 → 계정 → 계정 삭제</strong>를 누릅니다.</li>
<li>안내를 확인하고 삭제를 확정합니다.</li>
</ol>
<p>삭제 전에 기록을 보관하고 싶다면 설정 → AI 연동 → 내보내기에서 JSON·CSV로 받을 수 있습니다.</p>

<h2>앱을 쓸 수 없을 때 (이메일 요청)</h2>
<p>앱을 지웠거나 로그인할 수 없다면 <a href="mailto:$mail">$mail</a> 로 가입한 Google 계정 이메일 주소를 적어 삭제를 요청해 주세요. 본인 확인 후 영업일 기준 7일 안에 처리합니다.</p>

<h2>삭제되는 정보</h2>
<ul>
<li>계정 정보(Google 계정 식별자, 이메일, 이름)</li>
<li>모든 운동 기록, 체중·키·성별·출생 연도 등 신체 정보, 설정</li>
<li>프로그램·1RM 등 앱에서 만든 데이터, AI 연결 정보와 연결 기록</li>
</ul>
<p>삭제는 요청 즉시 서버 데이터베이스에서 이루어지며 되돌릴 수 없습니다.</p>

<h2>보관되는 정보와 기간</h2>
<ul>
<li>장애 복구용 백업에는 삭제 후 최대 <strong>${days}일</strong> 동안 남을 수 있으며, 그 뒤 자동으로 지워집니다. 백업은 장애 복구 외 용도로 쓰지 않습니다.</li>
<li>그 밖에 계정 삭제 후 보관하는 개인정보는 없습니다.</li>
</ul>

<p>자세한 내용은 <a href="/privacy">개인정보 처리방침</a>을 참고해 주세요.</p>
""".trimIndent()
        return page("fitlog 계정 삭제 안내", body)
    }

    private fun page(title: String, body: String): String = """
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${Markdown.escape(title)}</title>
<style>
:root { color-scheme: light dark; --bg: #ffffff; --fg: #1c1c1e; --line: #d9d9de; --link: #0b57d0; --head: #f2f2f5; }
@media (prefers-color-scheme: dark) { :root { --bg: #121214; --fg: #ececf0; --line: #3a3a40; --link: #8ab4f8; --head: #202024; } }
body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.65 system-ui, -apple-system, "Noto Sans KR", sans-serif; }
main { max-width: 760px; margin: 0 auto; padding: 24px 16px 64px; }
h1 { font-size: 1.6rem; line-height: 1.3; }
h2 { font-size: 1.2rem; margin-top: 2rem; }
a { color: var(--link); }
li { margin: 4px 0; }
table { border-collapse: collapse; width: 100%; display: block; overflow-x: auto; font-size: 0.92rem; }
th, td { border: 1px solid var(--line); padding: 8px 10px; text-align: left; vertical-align: top; }
th { background: var(--head); }
code { font-family: ui-monospace, monospace; background: var(--head); padding: 0 4px; border-radius: 4px; }
</style>
</head>
<body>
<main>
$body
</main>
</body>
</html>
""".trimStart()
}
