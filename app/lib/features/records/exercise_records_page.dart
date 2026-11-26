import 'package:material_ui/material_ui.dart';

class ExerciseRecordsPage extends StatelessWidget {
  const ExerciseRecordsPage({super.key, required this.exerciseId});
  final String exerciseId;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('records')),
    body: const Center(child: Text('TODO')),
  );
}
