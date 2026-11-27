// C 담당. AI 출처를 이니셜 원형 + 파란(ai) 톤으로 일관되게 보여준다(목업 11번).
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';

/// "Claude" → Cl, "ChatGPT" → GP, "Gemini" → Ge. 그 밖은 앞 두 글자.
String aiInitials(String name) {
  final n = name.trim();
  if (n.isEmpty) return '?';
  final lower = n.toLowerCase();
  if (lower.contains('chatgpt') || lower.contains('openai') || lower.contains('gpt')) return 'GP';
  if (lower.contains('claude')) return 'Cl';
  if (lower.contains('gemini')) return 'Ge';
  final chars = n.runes.take(2).map(String.fromCharCode).join();
  return chars.length == 1 ? chars.toUpperCase() : chars[0].toUpperCase() + chars.substring(1);
}

class AiAvatar extends StatelessWidget {
  const AiAvatar(this.name, {super.key, this.size = 40});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: c.aiSoft, shape: BoxShape.circle),
        child: Text(aiInitials(name), style: AppNum.style(context, size * 0.4, weight: FontWeight.w700, color: c.ai)),
      ),
    );
  }
}
