import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../ai/notes.dart';
import '../state/takes.dart';
import '../theme/tokens.dart';
import 'choice_chip.dart';
import 'widgets.dart';

/// Opens the transcript/summary sheet for a take. Runs the local AI service on
/// first use; the transcript's timestamps seek the player.
Future<void> openNotes(BuildContext context, Takes takes, Take take) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Tokens.surface,
    elevation: 0,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Tokens.r2)),
    ),
    builder: (_) => SheetSurface(child: _NotesSheet(takes: takes, take: take)),
  );
}

class _NotesSheet extends StatefulWidget {
  const _NotesSheet({required this.takes, required this.take});
  final Takes takes;
  final Take take;

  @override
  State<_NotesSheet> createState() => _NotesSheetState();
}

class _NotesSheetState extends State<_NotesSheet> {
  String template = 'meeting';
  bool showTranscript = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.takes.notes[widget.take.file.path];
    if (existing != null) template = existing.template;
    // Only start work when something is actually missing; an existing transcript
    // or summary is shown as-is.
    final action = notesAction(notes: existing, template: template);
    if (action != NotesAction.none) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
  }

  Future<void> _run() async {
    final notes = widget.takes.notes[widget.take.file.path];
    switch (notesAction(notes: notes, template: template)) {
      case NotesAction.transcribeAndSummarize:
        await widget.takes.generateNotes(widget.take, template: template);
      case NotesAction.summarizeOnly:
        await widget.takes.resummarize(widget.take, template);
      case NotesAction.none:
        break;
    }
  }

  Future<void> _editTitle() async {
    final controller = TextEditingController(text: widget.takes.titleFor(widget.take) ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Tokens.surface,
        title: Text('Title', style: Tokens.title),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: Tokens.body,
          decoration: const InputDecoration(hintText: 'Name this take'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (value != null) await widget.takes.setTitle(widget.take, value);
  }

  void _copy(String what, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$what copied'),
        backgroundColor: Tokens.ink,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _export(TakeNotes notes) async {
    final title = widget.takes.titleFor(widget.take) ?? widget.take.name;
    final safe = title.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${safe.isEmpty ? 'take' : safe}.md');
    await file.writeAsString(_markdown(notes, title));
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], text: title));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.takes,
      builder: (context, _) {
        final takes = widget.takes;
        final notes = takes.notes[widget.take.file.path];
        final busy = takes.working == widget.take.file.path;
        final error = takes.aiError;
        final title = takes.titleFor(widget.take);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Tokens.s5, Tokens.s4, Tokens.s5, Tokens.s5),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.85,
                maxWidth: 760,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: busy ? null : _editTitle,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      title ?? widget.take.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Tokens.title,
                                    ),
                                  ),
                                  const SizedBox(width: Tokens.s2),
                                  const Icon(Icons.edit, size: 14, color: Tokens.inkSoft),
                                ],
                              ),
                              Text(
                                '${widget.take.name} · ${widget.take.meta}',
                                style: Tokens.dataSmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close, size: 20),
                        color: Tokens.inkSoft,
                        tooltip: 'Close',
                      ),
                    ],
                  ),
                  const SizedBox(height: Tokens.s2),
                  Wrap(
                    spacing: Tokens.s2,
                    runSpacing: Tokens.s2,
                    children: [
                      for (final t in const ['meeting', 'lecture', 'plain'])
                        ChoiceChipButton(
                          label: t == 'plain' ? 'notes' : t,
                          compact: true,
                          selected: template == t,
                          onTap: busy
                              ? null
                              : () {
                                  setState(() => template = t);
                                  final action = notesAction(
                                    notes: takes.notes[widget.take.file.path],
                                    template: t,
                                  );
                                  if (action != NotesAction.none) _run();
                                },
                        ),
                    ],
                  ),
                  const SizedBox(height: Tokens.s1),
                  Wrap(
                    spacing: Tokens.s2,
                    runSpacing: Tokens.s2,
                    children: [
                      TextButton.icon(
                        onPressed: busy
                            ? null
                            : () => widget.takes
                                .generateNotes(widget.take, template: template, force: true),
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Redo'),
                      ),
                      if (notes != null && !busy) ...[
                        TextButton.icon(
                          onPressed: () => _copy('Summary', _summaryText(notes)),
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('Copy summary'),
                        ),
                        TextButton.icon(
                          onPressed: () => _copy('Transcript', _transcriptText(notes)),
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('Copy transcript'),
                        ),
                        TextButton.icon(
                          onPressed: () => _export(notes),
                          icon: const Icon(Icons.ios_share, size: 16),
                          label: const Text('Export .md'),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: Tokens.s1),
                  Row(
                    children: [
                      ChoiceChipButton(
                        label: 'Summary',
                        selected: !showTranscript,
                        onTap: () => setState(() => showTranscript = false),
                      ),
                      const SizedBox(width: Tokens.s2),
                      ChoiceChipButton(
                        label: 'Transcript',
                        selected: showTranscript,
                        onTap: () => setState(() => showTranscript = true),
                      ),
                    ],
                  ),
                  const SizedBox(height: Tokens.s3),
                  if (busy)
                    Row(children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Tokens.accent),
                      ),
                      const SizedBox(width: Tokens.s2),
                      Text('Working — transcribing and summarising…', style: Tokens.bodySmall),
                    ])
                  else if (error != null) ...[
                    Text(error, style: Tokens.bodySmall.copyWith(color: Tokens.danger)),
                    const SizedBox(height: Tokens.s2),
                    OutlinedButton(onPressed: _run, child: const Text('Try again')),
                  ] else if (notes != null)
                    Flexible(
                      child: _NotesBody(
                        takes: takes,
                        notes: notes,
                        showTranscript: showTranscript,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _NotesBody extends StatelessWidget {
  const _NotesBody({
    required this.takes,
    required this.notes,
    required this.showTranscript,
  });
  final Takes takes;
  final TakeNotes notes;
  final bool showTranscript;

  @override
  Widget build(BuildContext context) {
    if (!showTranscript) {
      if (notes.summarySections.every((s) => s.value.isEmpty)) {
        return Align(
          alignment: Alignment.topLeft,
          child: Text(
            'No summary yet — press Redo, or switch to Transcript.',
            style: Tokens.bodySmall,
          ),
        );
      }
      return ListView(
        shrinkWrap: true,
        children: [
          for (final section in notes.summarySections)
            if (section.value.isNotEmpty) ...[
              Text(section.key, style: Tokens.section),
              const SizedBox(height: Tokens.s1),
              for (final bullet in section.value)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('• $bullet', style: Tokens.body),
                ),
              const SizedBox(height: Tokens.s3),
            ],
          Text(
            '${notes.engine} · ${notes.summary?['engine'] ?? 'extractive'} summary',
            style: Tokens.caption,
          ),
        ],
      );
    }
    return ListView(
      shrinkWrap: true,
      children: [
        for (final seg in notes.segments)
          InkWell(
            onTap: () => takes.seek(Duration(milliseconds: (seg.start * 1000).round())),
            borderRadius: BorderRadius.circular(Tokens.r1),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 52,
                    child: Text(
                      seg.stamp,
                      style: Tokens.dataSmall.copyWith(color: Tokens.accent),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (seg.speaker != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 1),
                            child: Text(
                              seg.speaker!,
                              style: Tokens.dataSmall.copyWith(fontWeight: FontWeight.w500),
                            ),
                          ),
                        Text(seg.text, style: Tokens.body),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: Tokens.s2),
        Text(
          '${notes.language} · '
          '${NoteSegment.anyLabelled(notes.segments) ? 'speakers identified' : 'one speaker'}',
          style: Tokens.caption,
        ),
      ],
    );
  }
}

// --- text forms for copy / export -------------------------------------------

String _summaryText(TakeNotes notes) {
  final buffer = StringBuffer();
  for (final section in notes.summarySections) {
    if (section.value.isEmpty) continue;
    buffer.writeln('${section.key}:');
    for (final b in section.value) {
      buffer.writeln('• $b');
    }
    buffer.writeln();
  }
  return buffer.toString().trim();
}

String _transcriptText(TakeNotes notes) => notes.segments
    .map((s) => s.speaker == null ? s.text : '${s.speaker}: ${s.text}')
    .join('\n');

String _markdown(TakeNotes notes, String title) {
  final b = StringBuffer()
    ..writeln('# $title')
    ..writeln()
    ..writeln('_${notes.duration.toStringAsFixed(0)}s · ${notes.language} · '
        '${notes.summary?['engine'] ?? 'extractive'} summary_')
    ..writeln();
  final summary = _summaryText(notes);
  if (summary.isNotEmpty) {
    b
      ..writeln('## Summary')
      ..writeln(summary)
      ..writeln();
  }
  b.writeln('## Transcript');
  for (final s in notes.segments) {
    final who = s.speaker == null ? '' : '${s.speaker}: ';
    b.writeln('- `${s.stamp}` $who${s.text}');
  }
  return b.toString();
}
