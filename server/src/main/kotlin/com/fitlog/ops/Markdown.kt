package com.fitlog.ops

/**
 * 계약 문서용 아주 작은 마크다운 렌더러. 지원: # 제목, 문단, - 목록, 1. 목록, 표, **굵게**, `코드`, [링크](url), 맨 URL.
 * 모든 텍스트는 HTML 이스케이프하고, 링크는 http(s)·mailto·상대 경로만 허용한다.
 */
object Markdown {
    fun escape(s: String): String = buildString(s.length) {
        for (c in s) when (c) {
            '&' -> append("&amp;")
            '<' -> append("&lt;")
            '>' -> append("&gt;")
            '"' -> append("&quot;")
            '\'' -> append("&#39;")
            else -> append(c)
        }
    }

    fun render(md: String): String {
        val out = StringBuilder()
        val lines = md.replace("\r\n", "\n").split('\n')
        var i = 0
        while (i < lines.size) {
            val line = lines[i]
            when {
                line.isBlank() -> i++
                line.startsWith("#") -> {
                    val level = line.takeWhile { it == '#' }.length.coerceIn(1, 6)
                    out.append("<h$level>").append(inline(line.drop(level).trim())).append("</h$level>\n")
                    i++
                }
                isTableStart(lines, i) -> i = table(lines, i, out)
                isBullet(line) || isOrdered(line) -> {
                    val ordered = isOrdered(line)
                    val tag = if (ordered) "ol" else "ul"
                    out.append("<$tag>\n")
                    while (i < lines.size && (if (ordered) isOrdered(lines[i]) else isBullet(lines[i]))) {
                        val text = if (ordered) lines[i].replaceFirst(Regex("^\\d+\\.\\s+"), "") else lines[i].drop(2)
                        out.append("<li>").append(inline(text.trim())).append("</li>\n")
                        i++
                    }
                    out.append("</$tag>\n")
                }
                else -> {
                    val para = mutableListOf<String>()
                    while (i < lines.size && lines[i].isNotBlank() && !lines[i].startsWith("#") &&
                        !isBullet(lines[i]) && !isOrdered(lines[i]) && !isTableStart(lines, i)
                    ) para += lines[i++].trim()
                    out.append("<p>").append(inline(para.joinToString(" "))).append("</p>\n")
                }
            }
        }
        return out.toString()
    }

    private fun isBullet(l: String) = l.startsWith("- ") || l.startsWith("* ")
    private fun isOrdered(l: String) = Regex("^\\d+\\.\\s+.*").matches(l)
    private fun isTableStart(lines: List<String>, i: Int) =
        lines[i].trimStart().startsWith("|") && i + 1 < lines.size &&
            Regex("^\\s*\\|[\\s|:-]+\\|\\s*$").matches(lines[i + 1])

    private fun cells(line: String): List<String> =
        line.trim().removePrefix("|").removeSuffix("|").split('|').map { it.trim() }

    private fun table(lines: List<String>, start: Int, out: StringBuilder): Int {
        out.append("<table>\n<thead><tr>")
        cells(lines[start]).forEach { out.append("<th>").append(inline(it)).append("</th>") }
        out.append("</tr></thead>\n<tbody>\n")
        var i = start + 2
        while (i < lines.size && lines[i].trimStart().startsWith("|")) {
            out.append("<tr>")
            cells(lines[i]).forEach { out.append("<td>").append(inline(it)).append("</td>") }
            out.append("</tr>\n")
            i++
        }
        out.append("</tbody>\n</table>\n")
        return i
    }

    private val LINK = Regex("\\[([^\\]]+)]\\(([^)\\s]+)\\)")
    private val BARE_URL = Regex("https?://[^\\s<>\"')]+")
    private val BOLD = Regex("\\*\\*(.+?)\\*\\*")
    private val CODE = Regex("`([^`]+)`")

    private fun safeUrl(u: String) =
        u.startsWith("http://") || u.startsWith("https://") || u.startsWith("mailto:") || u.startsWith("/")

    /** 인라인: 링크·코드는 먼저 토큰으로 빼 두고, 나머지를 이스케이프한 뒤 굵게 처리, 마지막에 복원 */
    private fun inline(text: String): String {
        val stash = mutableListOf<String>()
        fun keep(html: String): String {
            stash += html
            return "\u0000${stash.size - 1}\u0000"
        }
        var t = LINK.replace(text) { m ->
            val url = m.groupValues[2]
            if (safeUrl(url)) keep("<a href=\"${escape(url)}\">${escape(m.groupValues[1])}</a>") else keep(escape(m.value))
        }
        t = CODE.replace(t) { keep("<code>${escape(it.groupValues[1])}</code>") }
        t = BARE_URL.replace(t) { keep("<a href=\"${escape(it.value)}\">${escape(it.value)}</a>") }
        t = escape(t)
        t = BOLD.replace(t) { "<strong>${it.groupValues[1]}</strong>" }
        return Regex("\u0000(\\d+)\u0000").replace(t) { stash[it.groupValues[1].toInt()] }
    }
}
