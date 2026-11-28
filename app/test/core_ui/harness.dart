import 'package:fitlog/core/theme.dart';
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget host(Widget home, {Locale locale = const Locale('ko')}) => MaterialApp(
  theme: AppTheme.light(),
  locale: locale,
  localizationsDelegates: [AppLocalizations.delegate, ...GlobalMaterialLocalizations.delegates],
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

/// 버튼 하나만 있는 화면. 누르면 [onTap]을 돌린다.
Widget opener(void Function(BuildContext) onTap) =>
    host(Scaffold(body: Builder(builder: (c) => TextButton(key: const Key('open'), onPressed: () => onTap(c), child: const Text('open')))));

Future<void> open(WidgetTester t) async {
  await t.tap(find.byKey(const Key('open')));
  await t.pumpAndSettle();
}
