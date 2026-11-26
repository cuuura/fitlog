import 'package:material_ui/material_ui.dart';

class ProgramStartPage extends StatelessWidget {
  const ProgramStartPage({super.key, required this.programId});
  final String programId;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('start')),
    body: const Center(child: Text('TODO')),
  );
}
