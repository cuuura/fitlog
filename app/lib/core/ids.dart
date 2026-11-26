import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// 모든 엔티티 ID는 클라이언트가 만드는 UUIDv7 (conventions.md).
String newId() => _uuid.v7();
