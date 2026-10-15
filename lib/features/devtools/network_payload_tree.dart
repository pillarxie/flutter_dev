import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A bounded view of an already decoded JSON payload. Copying remains owned by
/// the request section, so folding never changes the copied text.
class NetworkPayloadTree extends StatelessWidget {
  const NetworkPayloadTree({
    super.key,
    required this.value,
    required this.identity,
    required this.expanded,
    required this.onToggle,
  });
  final Object value;
  final String identity;
  final Map<String, bool> expanded;
  final ValueChanged<String> onToggle;

  static const _maximumNodes = 200;
  static const _maximumDepth = 12;
  static const _text = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: ['PingFang SC', 'Arial'],
    fontSize: 12,
    height: 1.6,
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    var nodes = 0;
    var limited = false;

    void visit(
      Object? value,
      String pointer,
      String path,
      String label,
      int depth,
    ) {
      if (nodes == _maximumNodes) {
        limited = true;
        return;
      }
      nodes++;
      final container = value is Map || value is List;
      final id = '$identity-$pointer';
      final open = expanded[id] ?? depth <= 1;
      final count = value is Map
          ? value.length
          : value is List
          ? value.length
          : 0;
      final summary = value is Map ? '{ $count 个字段 }' : '[ $count 项 ]';
      final canExpand = container && count > 0;
      rows.add(
        Padding(
          padding: EdgeInsets.only(left: math.min(depth, 3) * 12.0, bottom: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (canExpand)
                SizedBox(
                  width: 20,
                  height: 24,
                  child: IconButton(
                    key: ValueKey('network-payload-toggle-$id'),
                    tooltip: '${open ? '收起' : '展开'} $path',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 20,
                      height: 24,
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => onToggle(id),
                    icon: Icon(
                      open ? Icons.keyboard_arrow_down : Icons.chevron_right,
                      size: 16,
                    ),
                  ),
                ),
              if (!canExpand) const SizedBox(width: 20),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (label.isNotEmpty)
                      Tooltip(
                        message: path,
                        child: SelectableText(
                          label,
                          textWidthBasis: TextWidthBasis.longestLine,
                          style: _text.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ),
                    SelectableText(
                      container ? summary : jsonEncode(value),
                      textWidthBasis: TextWidthBasis.longestLine,
                      style: _text.copyWith(
                        color: container ? colors.primary : colors.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
      if (!canExpand || !open) return;
      if (depth == _maximumDepth) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(left: 36, bottom: 8),
            child: Text(
              '已达到展示深度上限，完整内容可通过复制查看。',
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
          ),
        );
        return;
      }
      if (value is Map) {
        var processed = 0;
        for (final entry in value.entries) {
          processed++;
          final name = entry.key.toString();
          final escaped = name.replaceAll('~', '~0').replaceAll('/', '~1');
          visit(
            entry.value,
            '$pointer/$escaped',
            '$path.$name',
            '$name:',
            depth + 1,
          );
          if (nodes == _maximumNodes) {
            limited = limited || processed < value.length;
            break;
          }
        }
      } else if (value is List) {
        for (var index = 0; index < value.length; index++) {
          visit(
            value[index],
            '$pointer/$index',
            '$path[$index]',
            '[$index]',
            depth + 1,
          );
          if (nodes == _maximumNodes) {
            limited = limited || index + 1 < value.length;
            break;
          }
        }
      }
    }

    visit(value, r'$', 'payload', '', 0);
    if (limited) {
      rows.add(
        Text(
          '节点较多，仅展示前 200 个可见节点；完整内容仍可复制。',
          style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}
