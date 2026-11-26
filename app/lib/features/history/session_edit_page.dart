import 'package:material_ui/material_ui.dart';

class SessionEditPage extends StatelessWidget {
  const SessionEditPage({super.key, required this.sessionId});
  final String sessionId;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('edit')),
    body: const Center(child: Text('TODO')),
  );
}
