import 'package:material_ui/material_ui.dart';

class AiHistoryDetailPage extends StatelessWidget {
  const AiHistoryDetailPage({super.key, required this.batchId});
  final String batchId;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('batch')),
    body: const Center(child: Text('TODO')),
  );
}
