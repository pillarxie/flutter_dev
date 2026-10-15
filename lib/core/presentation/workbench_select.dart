import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class WorkbenchOption<T> {
  const WorkbenchOption({
    required this.value,
    required this.label,
    this.detail,
    this.icon,
    this.enabled = true,
  });

  final T value;
  final String label;
  final String? detail;
  final IconData? icon;
  final bool enabled;
}

/// An anchored desktop selector using Flutter's menu focus and scrolling.
class WorkbenchSelect<T> extends StatefulWidget {
  const WorkbenchSelect({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    this.onChanged,
    this.hint = '请选择',
    this.menuWidth = 280,
  });

  final String label;
  final T? value;
  final List<WorkbenchOption<T>> options;
  final ValueChanged<T>? onChanged;
  final String hint;
  final double menuWidth;

  @override
  State<WorkbenchSelect<T>> createState() => _WorkbenchSelectState<T>();
}

class _WorkbenchSelectState<T> extends State<WorkbenchSelect<T>> {
  final _controller = MenuController();
  final _focus = FocusNode();

  bool get _enabled =>
      widget.onChanged != null &&
      widget.options.any((option) => option.enabled);

  @override
  void initState() {
    super.initState();
    _focus.addListener(_rebuild);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _toggle() {
    if (!_enabled) return;
    _controller.isOpen ? _controller.close() : _controller.open();
  }

  @override
  void dispose() {
    _focus.removeListener(_rebuild);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final selected = widget.options
        .where((option) => option.value == widget.value)
        .firstOrNull;
    final focusOption = selected?.enabled == true
        ? selected
        : widget.options.where((option) => option.enabled).firstOrNull;
    return LayoutBuilder(
      builder: (context, constraints) {
        final anchorWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : widget.menuWidth;
        final width = math.min(
          widget.menuWidth,
          math.min(
          math.max(200.0, anchorWidth),
            MediaQuery.sizeOf(context).width - 32,
          ),
        );
        return MenuAnchor(
          controller: _controller,
          childFocusNode: _focus,
          crossAxisUnconstrained: false,
          alignmentOffset: const Offset(0, 8),
          onOpen: _rebuild,
          onClose: _rebuild,
          style: MenuStyle(
            alignment: AlignmentDirectional.bottomStart,
            backgroundColor: WidgetStatePropertyAll(colors.surface),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
            elevation: const WidgetStatePropertyAll(6),
            shadowColor: WidgetStatePropertyAll(
              Colors.black.withValues(alpha: .18),
            ),
            side: WidgetStatePropertyAll(
              BorderSide(color: colors.outlineVariant),
            ),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
            minimumSize: WidgetStatePropertyAll(Size(width, 0)),
            maximumSize: WidgetStatePropertyAll(Size(width, 320)),
            visualDensity: VisualDensity.standard,
          ),
          menuChildren: [
            for (final option in widget.options)
              Semantics(
                selected: option.value == widget.value,
                child: MenuItemButton(
                  autofocus: identical(option, focusOption),
                  onPressed: _enabled && option.enabled
                      ? () {
                          if (mounted &&
                              _enabled &&
                              widget.options.any(
                                (current) =>
                                    current.value == option.value &&
                                    current.enabled,
                              )) {
                            widget.onChanged?.call(option.value);
                          }
                        }
                      : null,
                  leadingIcon: option.icon == null
                      ? null
                      : Icon(option.icon, size: 17),
                  trailingIcon: option.value == widget.value
                      ? Icon(
                          Icons.check_rounded,
                          size: 17,
                          color: colors.primary,
                        )
                      : const SizedBox(width: 17),
                  style: ButtonStyle(
                    minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    visualDensity: VisualDensity.standard,
                    shape: WidgetStatePropertyAll(
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(7),
                      ),
                    ),
                    backgroundColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.hovered) ||
                          states.contains(WidgetState.focused)) {
                        return colors.surfaceContainerHigh;
                      }
                      return option.value == widget.value
                          ? colors.primaryContainer.withValues(alpha: .55)
                          : Colors.transparent;
                    }),
                    foregroundColor: WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.disabled)
                          ? colors.onSurface.withValues(alpha: .38)
                          : colors.onSurface,
                    ),
                    textStyle: WidgetStatePropertyAll(
                      theme.textTheme.bodyMedium?.copyWith(fontSize: 13),
                    ),
                    overlayColor: const WidgetStatePropertyAll(
                      Colors.transparent,
                    ),
                    splashFactory: NoSplash.splashFactory,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        option.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (option.detail != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            option.detail!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: option.enabled
                                  ? colors.onSurfaceVariant
                                  : colors.onSurface.withValues(alpha: .38),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
          builder: (context, controller, child) => CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.arrowDown): () {
                if (_enabled && !controller.isOpen) controller.open();
              },
            },
            child: TextButton(
              focusNode: _focus,
              onPressed: _enabled ? _toggle : null,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: InputDecorator(
                isFocused: _focus.hasFocus || controller.isOpen,
                decoration: InputDecoration(
                  labelText: widget.label,
                  enabled: _enabled,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) => Row(
                    children: [
                      if (selected?.icon != null &&
                          constraints.maxWidth >= 144) ...[
                        Icon(
                          selected!.icon,
                          size: 16,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          selected?.label ?? widget.hint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 13,
                            color: _enabled
                                ? colors.onSurface
                                : colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: colors.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
