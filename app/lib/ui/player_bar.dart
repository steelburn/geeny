import 'package:flutter/material.dart';

import '../state/takes.dart';
import '../theme/tokens.dart';

/// `MM:SS`, or `H:MM:SS` once a take passes an hour.
String formatDuration(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// The scrubber itself: a slider that holds the position it was dragged to and
/// only seeks when the finger lifts, so the position stream cannot yank the
/// thumb out from under it.
///
/// Every player surface uses this one — the expanded take row and the notes
/// sheet — so seeking behaves the same in both, and the design of the track is
/// decided in one place.
class SeekSlider extends StatefulWidget {
  const SeekSlider({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
    this.height = 32,
  });

  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;
  final double height;

  @override
  State<SeekSlider> createState() => _SeekSliderState();
}

class _SeekSliderState extends State<SeekSlider> {
  Duration? _dragging;

  @override
  Widget build(BuildContext context) {
    final maxMs = widget.duration.inMilliseconds > 0
        ? widget.duration.inMilliseconds.toDouble()
        : 1.0;
    final shown = (_dragging ?? widget.position).inMilliseconds.toDouble().clamp(0.0, maxMs);

    return SizedBox(
      height: widget.height,
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3,
          activeTrackColor: Tokens.accent,
          inactiveTrackColor: Tokens.ruleStrong,
          thumbColor: Tokens.accent,
          overlayColor: Tokens.accent.withValues(alpha: 0.12),
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
          trackShape: const RoundedRectSliderTrackShape(),
        ),
        child: Slider(
          value: shown,
          max: maxMs,
          semanticFormatterCallback: (v) =>
              '${formatDuration(Duration(milliseconds: v.round()))} of ${formatDuration(widget.duration)}',
          onChangeStart: (v) => setState(() => _dragging = Duration(milliseconds: v.round())),
          onChanged: (v) => setState(() => _dragging = Duration(milliseconds: v.round())),
          onChangeEnd: (v) {
            // Fire and forget: the position stream reports the new spot, and the
            // thumb is released here so it follows it.
            widget.onSeek(Duration(milliseconds: v.round()));
            setState(() => _dragging = null);
          },
        ),
      ),
    );
  }
}

/// The playback bar used by the notes sheet: title, play/pause, scrubber.
///
/// The takes list does not use this — there the scrubber lives inside the row of
/// the recording that is playing (see `takes_section.dart`), so a separate bar
/// above the list cannot be mistaken for the top recording being in playback.
/// Here a bar makes sense: the sheet is a different surface from the row.
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key, required this.takes, this.onlyFor, this.compact = false});

  final Takes takes;

  /// Hides the title line, which the notes sheet header already shows.
  final bool compact;

  /// Only show the bar while this take is the one loaded in the player, so a
  /// scrubber is never offered for a different recording than the transcript on
  /// screen.
  final Take? onlyFor;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: takes,
      builder: (context, _) {
        final take = takes.current;
        if (take == null) return const SizedBox.shrink();
        final onlyFor = this.onlyFor;
        if (onlyFor != null && onlyFor.file.path != take.file.path) {
          return const SizedBox.shrink();
        }
        final title = takes.titleFor(take) ?? take.humanDate;
        final playing = takes.isPlaying;

        return Material(
          color: Tokens.accentSoft,
          child: Container(
            padding: const EdgeInsets.fromLTRB(Tokens.s2, Tokens.s1, Tokens.s1, Tokens.s1),
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: Tokens.rule),
                bottom: BorderSide(color: Tokens.rule),
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => takes.toggle(take),
                  tooltip: playing ? 'Pause' : 'Play',
                  iconSize: 20,
                  color: Tokens.accent,
                  constraints: const BoxConstraints(
                    minWidth: Tokens.targetCompact,
                    minHeight: Tokens.targetCompact,
                  ),
                  icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                ),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!compact)
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Tokens.bodySmall.copyWith(
                            fontWeight: FontWeight.w600,
                            color: Tokens.ink,
                          ),
                        ),
                      Row(
                        children: [
                          Expanded(
                            child: SeekSlider(
                              key: ValueKey(take.file.path),
                              position: takes.position,
                              duration: takes.duration,
                              onSeek: takes.seek,
                              height: compact ? 28 : 32,
                            ),
                          ),
                          const SizedBox(width: Tokens.s2),
                          Text(
                            '${formatDuration(takes.position)} / ${formatDuration(takes.duration)}',
                            style: Tokens.dataSmall.copyWith(color: Tokens.inkSoft),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => takes.stop(),
                  tooltip: 'Stop',
                  iconSize: 18,
                  color: Tokens.inkSoft,
                  constraints: const BoxConstraints(
                    minWidth: Tokens.targetCompact,
                    minHeight: Tokens.targetCompact,
                  ),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
