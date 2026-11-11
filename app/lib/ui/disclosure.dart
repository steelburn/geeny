import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// A section whose body can be folded away. Used for anything that is setup or
/// diagnosis rather than daily use.
///
/// Motion is skipped when the system asks for reduced motion.
class Disclosure extends StatefulWidget {
  const Disclosure({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.initiallyOpen = false,
  });

  final String title;
  final Widget child;
  final Widget? trailing;
  final bool initiallyOpen;

  @override
  State<Disclosure> createState() => _DisclosureState();
}

class _DisclosureState extends State<Disclosure> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final duration = reduce ? Duration.zero : const Duration(milliseconds: 180);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: _open,
          label: '${widget.title}, ${_open ? 'expanded' : 'collapsed'}',
          child: InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(Tokens.r1),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: Tokens.targetCompact),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Tokens.s2),
                child: Row(
                  children: [
                    Text(widget.title, style: Tokens.section),
                    const Spacer(),
                    if (widget.trailing != null) ...[
                      widget.trailing!,
                      const SizedBox(width: Tokens.s2),
                    ],
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: duration,
                      child: const Icon(Icons.expand_more, size: 18, color: Tokens.inkSoft),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        AnimatedSize(
          duration: duration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !_open
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: Tokens.s3),
                  child: widget.child,
                ),
        ),
      ],
    );
  }
}
