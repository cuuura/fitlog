// B3 소유. 세션 화면을 감싸면 설정(keepScreenOn)에 따라 화면 꺼짐을 막는다. 골격은 아무것도 하지 않는다.
import 'package:material_ui/material_ui.dart';

class SessionWakelock extends StatelessWidget {
  final Widget child;
  const SessionWakelock({super.key, required this.child});
  @override
  Widget build(BuildContext context) => child;
}
