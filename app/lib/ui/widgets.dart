import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// A modal surface: nearer than a card, so it carries the second elevation.
class SheetSurface extends StatelessWidget {
  const SheetSurface({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Tokens.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(Tokens.r2)),
        boxShadow: Tokens.elev2,
      ),
      child: child,
    );
  }
}

class Section extends StatelessWidget {
  const Section({super.key, required this.title, required this.child, this.trailing, this.hint});

  final String title;
  final Widget child;
  final Widget? trailing;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(title, style: Tokens.section),
            const Spacer(),
            ?trailing,
          ],
        ),
        const SizedBox(height: Tokens.s1),
        const Divider(height: 1),
        const SizedBox(height: Tokens.s3),
        child,
        if (hint != null) ...[
          const SizedBox(height: Tokens.s2),
          Text(hint!, style: Tokens.caption),
        ],
      ],
    );
  }
}

class Fact extends StatelessWidget {
  const Fact({super.key, required this.label, required this.value, this.emphasis = false});

  final String label;
  final String value;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Tokens.s2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 84, child: Text(label, style: Tokens.bodySmall)),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: Tokens.data.copyWith(
                color: emphasis ? Tokens.ink : Tokens.ink.withValues(alpha: 0.9),
                fontWeight: emphasis ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.state, required this.label});

  final String state;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      'connected' => Tokens.accent,
      'scanning' => Tokens.warn,
      _ => Tokens.dotIdle,
    };
    return Semantics(
      label: 'Status: $label',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: Tokens.s2),
          Text(
            label,
            style: Tokens.dataSmall.copyWith(
              color: state == 'connected' ? Tokens.accent : Tokens.inkSoft,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class ErrorStrip extends StatelessWidget {
  const ErrorStrip({super.key, required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: Tokens.s2),
      padding: const EdgeInsets.fromLTRB(Tokens.s3, Tokens.s2, Tokens.s1, Tokens.s2),
      decoration: BoxDecoration(
        color: Tokens.dangerSoft,
        borderRadius: BorderRadius.circular(Tokens.r2),
        border: Border.all(color: Tokens.danger.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('!!', style: Tokens.dataSmall.copyWith(color: Tokens.danger, fontWeight: FontWeight.w500)),
          ),
          const SizedBox(width: Tokens.s2),
          Expanded(child: Text(message, style: Tokens.bodySmall.copyWith(color: Tokens.danger))),
          TextButton(
            onPressed: onDismiss,
            style: TextButton.styleFrom(foregroundColor: Tokens.danger),
            child: const Text('Dismiss'),
          ),
        ],
      ),
    );
  }
}
