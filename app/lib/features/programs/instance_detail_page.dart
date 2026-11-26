import 'package:material_ui/material_ui.dart';

class InstanceDetailPage extends StatelessWidget {
  const InstanceDetailPage({super.key, required this.instanceId});
  final String instanceId;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('instance')),
    body: const Center(child: Text('TODO')),
  );
}
