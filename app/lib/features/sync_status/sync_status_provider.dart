import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../domain/repositories.dart';

final syncStatusProvider = StreamProvider<SyncStatus>((ref) => ref.watch(syncServiceProvider).watchStatus());
