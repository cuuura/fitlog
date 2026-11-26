import 'package:material_ui/material_ui.dart';

class ProgramDetailPage extends StatelessWidget {
  const ProgramDetailPage({super.key, required this.programId});
  final String programId;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('program')),
    body: const Center(child: Text('TODO')),
  );
}
