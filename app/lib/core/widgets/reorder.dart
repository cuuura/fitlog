// 드래그로 순서 바꾸기 공용 도우미: 끄는 동안의 모양(proxy), 햅틱, 목록 이동.
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// [list]에서 [from] 위치 항목을 [to]로 옮긴 새 목록. [to]는 onReorderItem이 주는(이미 보정된) 값.
List<T> movedItem<T>(List<T> list, int from, int to) {
  final out = [...list];
  out.insert(to, out.removeAt(from));
  return out;
}

/// 드래그 시작 햅틱. 테스트·지원 안 하는 기기에서는 조용히 무시된다.
void reorderHaptic() {
  HapticFeedback.selectionClick();
}

/// ReorderableListView.proxyDecorator 용: 떠 있는 카드처럼 그림자를 준다.
/// [compact]를 주면 원래 항목 대신 그 위젯(예: 접힌 카드)을 띄운다.
ReorderItemProxyDecorator reorderProxy({Widget Function(int index)? compact}) {
  return (Widget child, int index, Animation<double> animation) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, c) {
        final t = Curves.easeInOut.transform(animation.value);
        return Material(
          elevation: 2 + 6 * t,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: c,
        );
      },
      child: compact == null ? child : compact(index),
    );
  };
}
