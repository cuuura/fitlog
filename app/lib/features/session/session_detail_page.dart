import 'package:material_ui/material_ui.dart';

class SessionDetailPage extends StatelessWidget {
  const SessionDetailPage({super.key, required this.sessionId});
  final String sessionId;
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('session')), body: const Center(child: Text('TODO')));
}
