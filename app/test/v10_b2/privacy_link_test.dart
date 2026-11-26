import 'package:fitlog/features/settings/privacy_link.dart';
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget host(Widget child) => MaterialApp(
  localizationsDelegates: [AppLocalizations.delegate, ...GlobalMaterialLocalizations.delegates],
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('ko'),
  home: Scaffold(body: child),
);

void main() {
  test('privacyPolicyUri는 끝 슬래시를 정리한다', () {
    expect(privacyPolicyUri('https://api.example.com').toString(), 'https://api.example.com/privacy');
    expect(privacyPolicyUri('https://api.example.com/').toString(), 'https://api.example.com/privacy');
  });

  testWidgets('탭하면 /privacy를 연다', (tester) async {
    Uri? opened;
    await tester.pumpWidget(
      host(
        PrivacyPolicyTile(
          open: (u) async {
            opened = u;
            return true;
          },
          uri: Uri.parse('https://x.test/privacy'),
        ),
      ),
    );
    expect(find.text('개인정보 처리방침'), findsOneWidget);
    await tester.tap(find.byType(ListTile));
    await tester.pump();
    expect(opened.toString(), 'https://x.test/privacy');
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('열지 못하면 안내', (tester) async {
    await tester.pumpWidget(host(PrivacyPolicyTile(open: (_) async => false)));
    await tester.tap(find.byType(ListTile));
    await tester.pump();
    expect(find.text('링크를 열지 못했어요. 잠시 후 다시 시도해 주세요.'), findsOneWidget);
  });
}
