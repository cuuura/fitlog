// 편집기 입력 칸들. 값은 정의 Map의 한 칸에 바로 쓰고, 비우면 그 칸을 지운다(선택 필드).
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'program_definition.dart';

String fmtNum(num? v) {
  if (v == null) return '';
  final d = v.toDouble();
  if (d == d.roundToDouble()) return d.toInt().toString();
  return double.parse(d.toStringAsFixed(4)).toString();
}

/// 숫자 칸. [scale]이 100이면 화면은 퍼센트, 저장은 비율.
class MapNumField extends StatefulWidget {
  const MapNumField({
    super.key,
    required this.map,
    required this.field,
    required this.label,
    this.integer = false,
    this.scale = 1,
    this.suffix,
    this.helper,
    this.errorText,
    this.onChanged,
  });
  final Json map;
  final String field;
  final String label;
  final bool integer;
  final double scale;
  final String? suffix;
  final String? helper;
  final String? errorText;
  final VoidCallback? onChanged;

  @override
  State<MapNumField> createState() => _MapNumFieldState();
}

class _MapNumFieldState extends State<MapNumField> {
  late final TextEditingController _c;

  @override
  void initState() {
    super.initState();
    final v = widget.map[widget.field];
    _c = TextEditingController(text: v is num ? fmtNum(v * widget.scale) : '');
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _changed(String t) {
    final text = t.trim().replaceAll(',', '.');
    final parsed = double.tryParse(text);
    if (parsed == null) {
      widget.map.remove(widget.field);
    } else if (widget.integer) {
      widget.map[widget.field] = parsed.round();
    } else {
      final v = parsed / widget.scale;
      widget.map[widget.field] = double.parse(v.toStringAsFixed(6));
    }
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      onChanged: _changed,
      keyboardType: TextInputType.numberWithOptions(decimal: !widget.integer, signed: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\-]'))],
      decoration: InputDecoration(
        isDense: true,
        labelText: widget.label,
        suffixText: widget.suffix,
        helperText: widget.helper,
        errorText: widget.errorText,
        errorMaxLines: 3,
        border: const OutlineInputBorder(),
      ),
    );
  }
}

class MapTextField extends StatefulWidget {
  const MapTextField({
    super.key,
    required this.map,
    required this.field,
    required this.label,
    this.maxLength,
    this.maxLines = 1,
    this.errorText,
    this.onChanged,
  });
  final Json map;
  final String field;
  final String label;
  final int? maxLength;
  final int? maxLines;
  final String? errorText;
  final VoidCallback? onChanged;

  @override
  State<MapTextField> createState() => _MapTextFieldState();
}

class _MapTextFieldState extends State<MapTextField> {
  late final TextEditingController _c;

  @override
  void initState() {
    super.initState();
    final v = widget.map[widget.field];
    _c = TextEditingController(text: v is String ? v : '');
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      maxLength: widget.maxLength,
      maxLines: widget.maxLines,
      onChanged: (t) {
        if (t.trim().isEmpty && widget.field != 'name') {
          widget.map.remove(widget.field);
        } else {
          widget.map[widget.field] = t;
        }
        widget.onChanged?.call();
      },
      decoration: InputDecoration(
        isDense: true,
        labelText: widget.label,
        errorText: widget.errorText,
        errorMaxLines: 3,
        border: const OutlineInputBorder(),
      ),
    );
  }
}

/// 켜기·끄기. 기본값과 같으면 그 칸을 지워 정의를 깔끔하게 둔다.
class MapSwitch extends StatelessWidget {
  const MapSwitch({
    super.key,
    required this.map,
    required this.field,
    required this.label,
    this.defaultValue = false,
    this.subtitle,
    required this.onChanged,
  });
  final Json map;
  final String field;
  final String label;
  final bool defaultValue;
  final String? subtitle;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final cur = map[field] is bool ? map[field] as bool : defaultValue;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: subtitle == null ? null : Text(subtitle!),
      value: cur,
      onChanged: (v) {
        if (v == defaultValue) {
          map.remove(field);
        } else {
          map[field] = v;
        }
        onChanged();
      },
    );
  }
}

/// 고르기 칸. [allowNone]이면 첫 항목이 "고르지 않음"이고 고르면 그 칸을 지운다.
class MapDropdown extends StatelessWidget {
  const MapDropdown({
    super.key,
    required this.map,
    required this.field,
    required this.label,
    required this.options,
    this.noneLabel,
    this.defaultValue,
    this.errorText,
    required this.onChanged,
  });
  final Json map;
  final String field;
  final String label;

  /// 값 → 화면 이름.
  final Map<String, String> options;
  final String? noneLabel;

  /// 칸이 없을 때 화면에 보여 줄 값(스키마 기본값).
  final String? defaultValue;
  final String? errorText;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final raw = map[field];
    final cur = raw is String && options.containsKey(raw) ? raw : (noneLabel == null ? defaultValue : null);
    return DropdownButtonFormField<String?>(
      key: ValueKey('$field-$cur'),
      initialValue: cur,
      isExpanded: true,
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        errorText: errorText,
        errorMaxLines: 3,
        border: const OutlineInputBorder(),
      ),
      items: [
        if (noneLabel != null) DropdownMenuItem<String?>(value: null, child: Text(noneLabel!)),
        for (final e in options.entries) DropdownMenuItem<String?>(value: e.key, child: Text(e.value)),
      ],
      onChanged: (v) {
        if (v == null) {
          map.remove(field);
        } else {
          map[field] = v;
        }
        onChanged();
      },
    );
  }
}
