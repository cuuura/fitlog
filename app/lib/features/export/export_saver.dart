import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 내보낸 파일을 임시 폴더에 쓰고 공유 시트를 연다. 테스트는 가짜로 바꾼다.
abstract interface class ExportSaver {
  Future<void> save({required String fileName, required String content, required String mimeType});
}

class SharePlusExportSaver implements ExportSaver {
  const SharePlusExportSaver();

  @override
  Future<void> save({required String fileName, required String content, required String mimeType}) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(content, flush: true);
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: mimeType, name: fileName)]));
  }
}

final exportSaverProvider = Provider<ExportSaver>((ref) => const SharePlusExportSaver());
