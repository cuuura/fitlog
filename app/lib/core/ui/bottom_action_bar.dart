import 'package:material_ui/material_ui.dart';

import '../theme.dart';

/// 화면 하단에 고정되는 주 행동 자리. Scaffold.bottomNavigationBar에 넣는다.
class BottomActionBar extends StatelessWidget {
  const BottomActionBar({super.key, required this.child, this.error});
  final Widget child;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(top: BorderSide(color: c.line)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (error != null) ...[
                  Text(error!, style: TextStyle(color: c.fail)),
                  const SizedBox(height: 8),
                ],
                SizedBox(width: double.infinity, child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
