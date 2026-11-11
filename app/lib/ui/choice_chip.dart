import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// A selection chip with the states the rest of the app has: focus ring, pressed
/// tint, disabled, and `selected` exposed to accessibility services.
///
/// Every segmented control in the app uses this, so chips cannot drift away from
/// the button states defined in the theme.
class ChoiceChipButton extends StatefulWidget {
  const ChoiceChipButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  /// 36 dp instead of 44 — only for dense filter rows that sit inside a panel.
  final bool compact;
  final IconData? icon;

  @override
  State<ChoiceChipButton> createState() => _ChoiceChipButtonState();
}

class _ChoiceChipButtonState extends State<ChoiceChipButton> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final bg = !enabled
        ? Tokens.paper
        : widget.selected
            ? (_hovered ? Tokens.accentPressed : Tokens.accent)
            : (_hovered ? const Color(0xFFFFFFFF) : Tokens.surface);
    final fg = !enabled
        ? Tokens.inkSoft.withValues(alpha: 0.45)
        : widget.selected
            ? Tokens.onAccent
            : Tokens.ink;
    final border = _focused
        ? Tokens.ink
        : widget.selected
            ? Tokens.accent
            : Tokens.ruleStrong;

    return Semantics(
      button: true,
      selected: widget.selected,
      enabled: enabled,
      label: widget.label,
      child: FocusableActionDetector(
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
            onTap: widget.onTap,
            behavior: HitTestBehavior.opaque,
            child: Container(
              constraints: BoxConstraints(
                minHeight: widget.compact ? Tokens.targetCompact : Tokens.target,
              ),
              padding: EdgeInsets.symmetric(
                horizontal: widget.compact ? Tokens.s3 : Tokens.s4,
                vertical: Tokens.s2,
              ),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(Tokens.r1),
                border: Border.all(
                  color: border,
                  width: _focused ? 2 : 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.icon != null) ...[
                    Icon(widget.icon, size: 15, color: fg),
                    const SizedBox(width: Tokens.s1),
                  ],
                  Text(
                    widget.label,
                    style: Tokens.bodySmall.copyWith(
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
