import 'package:material_ui/material_ui.dart';

class SessionSummaryPage extends StatelessWidget {
  const SessionSummaryPage({super.key, required this.sessionId});
  final String sessionId;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('summary')),
    body: const Center(child: Text('TODO')),
  );
}
