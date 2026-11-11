import 'package:flutter/material.dart';

import '../state/takes.dart';
import '../theme/tokens.dart';
import 'choice_chip.dart';
import 'notes_sheet.dart';
import 'widgets.dart';

/// The pulled takes, as a ruled ledger: one line each, newest first, with the
/// project filter above. Everything else about a take lives in its action sheet.
class TakesSection extends StatelessWidget {
  const TakesSection({super.key, required this.takes, this.playingPath});

  final Takes takes;
  final String? playingPath;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: takes,
      builder: (context, _) {
        final items = takes.visible;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('Takes', style: Tokens.section),
                const Spacer(),
                TextButton.icon(
                  onPressed: takes.importing ? null : () => _openImport(context, takes),
                  icon: Icon(takes.importing ? Icons.hourglass_empty : Icons.file_download_outlined,
                      size: 16),
                  label: Text(takes.importing ? 'Importing…' : 'Import'),
                ),
                const SizedBox(width: Tokens.s2),
                Text(items.length == takes.items.length
                    ? '${items.length} saved'
                    : '${items.length} of ${takes.items.length}',
                    style: Tokens.dataSmall),
              ],
            ),
            const SizedBox(height: Tokens.s1),
            const Divider(height: 1),
            if (takes.notice != null)
              Padding(
                padding: const EdgeInsets.only(top: Tokens.s2),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(Tokens.s3, Tokens.s2, Tokens.s1, Tokens.s2),
                  decoration: BoxDecoration(
                    color: Tokens.accentSoft,
                    borderRadius: BorderRadius.circular(Tokens.r2),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Icon(Icons.check_circle_outline, size: 16, color: Tokens.accent),
                      ),
                      const SizedBox(width: Tokens.s2),
                      Expanded(child: Text(takes.notice!, style: Tokens.bodySmall)),
                      TextButton(
                        onPressed: takes.dismissNotice,
                        child: const Text('Dismiss'),
                      ),
                    ],
                  ),
                ),
              ),
            if (takes.projects.isNotEmpty || takes.unfiledCount > 0) ...[
              const SizedBox(height: Tokens.s2),
              Wrap(
                spacing: Tokens.s2,
                runSpacing: Tokens.s2,
                children: [
                  ChoiceChipButton(
                    label: 'All',
                    compact: true,
                    selected: takes.filter == 'all',
                    onTap: () => takes.setFilter('all'),
                  ),
                  if (takes.unfiledCount > 0)
                    ChoiceChipButton(
                      label: 'Unfiled (${takes.unfiledCount})',
                      compact: true,
                      selected: takes.filter == 'unfiled',
                      onTap: () => takes.setFilter('unfiled'),
                    ),
                  for (final p in takes.projects)
                    ChoiceChipButton(
                      label: p,
                      compact: true,
                      selected: takes.filter == p,
                      onTap: () => takes.setFilter(p),
                    ),
                ],
              ),
            ],
            const SizedBox(height: Tokens.s2),
            if (takes.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: Tokens.s2),
                child: Text(takes.error!,
                    style: Tokens.bodySmall.copyWith(color: Tokens.danger)),
              ),
            Expanded(
              child: items.isEmpty
                  ? _EmptyTakes(filter: takes.filter)
                  : ListView.separated(
                      padding: EdgeInsets.zero,
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final take = items[i];
                        final active = playingPath == take.file.path;
                        return _TakeRow(
                          take: take,
                          title: takes.titleFor(take),
                          active: active,
                          playing: active && takes.isPlaying,
                          hasNotes: takes.notes.containsKey(take.file.path),
                          onPressed: () => takes.toggle(take),
                          onOpen: () => _rowActions(context, takes, take),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _EmptyTakes extends StatelessWidget {
  const _EmptyTakes({required this.filter});
  final String filter;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: Tokens.s3),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Text(
            filter == 'unfiled'
                ? 'Every take has a project. Switch back to All to see them together.'
                : 'No takes yet. Record with the device and fetch it here, or import a '
                    'recording or transcript you exported from Boya OS. A take shows its '
                    'title once it has been transcribed.',
            style: Tokens.bodySmall,
          ),
        ),
      ),
    );
  }
}

/// Import: the share sheet, or a file exported to Downloads.
///
/// Boya OS has no import API — its recordings live in its cloud — so the honest
/// path is the one that app already offers: Share, and its Export menu.
Future<void> _openImport(BuildContext context, Takes takes) async {
  final pick = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Tokens.surface,
    elevation: 0,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Tokens.r2)),
    ),
    builder: (ctx) => SheetSurface(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Tokens.s5, Tokens.s4, Tokens.s5, Tokens.s4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('Import from Boya OS', style: Tokens.title),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    constraints: const BoxConstraints(
                      minWidth: Tokens.target,
                      minHeight: Tokens.target,
                    ),
                    icon: const Icon(Icons.close, size: 20, color: Tokens.inkSoft),
                    tooltip: 'Close',
                  ),
                ],
              ),
              const SizedBox(height: Tokens.s2),
              Text(
                'Boya OS keeps its recordings in its own account, so Geeny cannot read them '
                'directly. It does accept what that app can export:',
                style: Tokens.bodySmall,
              ),
              const SizedBox(height: Tokens.s3),
              const _ImportStep(
                step: '1',
                title: 'Recording',
                detail: 'In Boya OS choose Share \u2192 Geeny, or Export audio and pick the file '
                    'below. Ogg Opus transcribes on your machine; MP3 and M4A play here but '
                    'need an external speech service.',
              ),
              const SizedBox(height: Tokens.s3),
              const _ImportStep(
                step: '2',
                title: 'Transcript and summary',
                detail: 'Export as TXT, Markdown or SRT and share it. It is attached to the '
                    'take with the same name, or kept as a transcript-only take. DOCX and PDF '
                    'are not readable here.',
              ),
              const SizedBox(height: Tokens.s4),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('Choose a file'),
                  ),
                  const SizedBox(width: Tokens.s3),
                  Expanded(
                    child: Text(
                      'Sharing from another app sends the file straight here.',
                      style: Tokens.caption,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Tokens.s2),
            ],
          ),
        ),
      ),
    ),
  );
  if (pick == true && context.mounted) {
    await takes.importFromPicker();
  }
}

class _ImportStep extends StatelessWidget {
  const _ImportStep({required this.step, required this.title, required this.detail});
  final String step;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 22,
          child: Text(step, style: Tokens.dataSmall.copyWith(color: Tokens.accent)),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Tokens.body.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 1),
              Text(detail, style: Tokens.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

class _TakeRow extends StatelessWidget {
  const _TakeRow({
    required this.take,
    required this.active,
    required this.playing,
    required this.onPressed,
    required this.onOpen,
    this.hasNotes = false,
    this.title,
  });

  final Take take;
  final bool active;
  final bool playing;
  final VoidCallback onPressed;
  final VoidCallback onOpen;
  final bool hasNotes;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? Tokens.accentSoft : Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: active ? Tokens.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(vertical: Tokens.s1),
          child: Row(
            children: [
              IconButton(
                onPressed: take.hasAudio ? onPressed : null,
                iconSize: 20,
                tooltip: take.hasAudio
                    ? (playing ? 'Pause' : 'Play')
                    : 'Transcript only — the audio stayed in Boya OS',
                constraints: const BoxConstraints(
                  minWidth: Tokens.target,
                  minHeight: Tokens.target,
                ),
                style: IconButton.styleFrom(
                  foregroundColor: active ? Tokens.accent : Tokens.ink,
                  disabledForegroundColor: Tokens.inkSoft.withValues(alpha: 0.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Tokens.r1),
                    side: const BorderSide(color: Tokens.ruleStrong),
                  ),
                ),
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              ),
              const SizedBox(width: Tokens.s2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title ?? take.humanDate,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Tokens.body.copyWith(
                        fontWeight: title != null ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    Text(
                      title != null ? take.name : '${take.name} · untitled',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Tokens.dataSmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Tokens.s2),
              Text(take.meta, style: Tokens.dataSmall),
              if (hasNotes) ...[
                const SizedBox(width: Tokens.s2),
                const Icon(Icons.notes, size: 16, color: Tokens.accent),
              ],
              IconButton(
                onPressed: onOpen,
                tooltip: 'Actions for ${title ?? take.humanDate}',
                iconSize: 18,
                constraints: const BoxConstraints(
                  minWidth: Tokens.target,
                  minHeight: Tokens.target,
                ),
                color: Tokens.inkSoft,
                icon: const Icon(Icons.more_horiz),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Row actions: the three things you do with a take.
Future<void> _rowActions(BuildContext context, Takes takes, Take take) async {
  final title = takes.titleFor(take);
  final playing = takes.current?.file.path == take.file.path && takes.isPlaying;
  final action = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: Tokens.surface,
    elevation: 0,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Tokens.r2)),
    ),
    builder: (ctx) => SheetSurface(
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Tokens.s5, Tokens.s4, Tokens.s5, Tokens.s2),
              child: Text('${title ?? take.humanDate}  ·  ${take.meta}',
                  style: Tokens.dataSmall),
            ),
            if (take.hasAudio)
              ListTile(
                minVerticalPadding: Tokens.s3,
                leading: Icon(playing ? Icons.pause : Icons.play_arrow, color: Tokens.ink),
                title: Text(playing ? 'Pause' : 'Play', style: Tokens.body),
                onTap: () => Navigator.of(ctx).pop('play'),
              ),
            ListTile(
              minVerticalPadding: Tokens.s3,
              leading: Icon(takes.notes.containsKey(take.file.path) ? Icons.notes : Icons.article_outlined,
                  color: Tokens.accent),
              title: Text(
                takes.notes.containsKey(take.file.path) ? 'Show transcript' : 'Transcribe & summarise',
                style: Tokens.body,
              ),
              onTap: () => Navigator.of(ctx).pop('notes'),
            ),
            ListTile(
              minVerticalPadding: Tokens.s3,
              leading: const Icon(Icons.folder_outlined, color: Tokens.ink),
              title: Text(
                takes.projectOf[take.file.path] == null
                    ? 'Add to project…'
                    : 'Project: ${takes.projectOf[take.file.path]}',
                style: Tokens.body,
              ),
              onTap: () => Navigator.of(ctx).pop('project'),
            ),
            ListTile(
              minVerticalPadding: Tokens.s3,
              leading: const Icon(Icons.delete_outline, color: Tokens.danger),
              title: Text('Delete', style: Tokens.body.copyWith(color: Tokens.danger)),
              onTap: () => Navigator.of(ctx).pop('delete'),
            ),
            const SizedBox(height: Tokens.s2),
          ],
        ),
      ),
    ),
  );
  if (!context.mounted || action == null) return;
  switch (action) {
    case 'play':
      await takes.toggle(take);
    case 'notes':
      await openNotes(context, takes, take);
    case 'project':
      await _chooseProject(context, takes, take);
    case 'delete':
      await _confirmDelete(context, takes, take);
  }
}

/// Pick an existing project or type a new one.
Future<void> _chooseProject(BuildContext context, Takes takes, Take take) async {
  final controller = TextEditingController(text: takes.projectOf[take.file.path] ?? '');
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Tokens.surface,
      title: Text('Project', style: Tokens.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (takes.projects.isNotEmpty) ...[
            Wrap(
              spacing: Tokens.s2,
              runSpacing: Tokens.s2,
              children: [
                for (final p in takes.projects)
                  TextButton(onPressed: () => Navigator.of(ctx).pop(p), child: Text(p)),
              ],
            ),
            const SizedBox(height: Tokens.s2),
          ],
          TextField(
            controller: controller,
            autofocus: true,
            style: Tokens.body,
            decoration: const InputDecoration(hintText: 'New project name'),
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop('__none__'), child: const Text('No project')),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (!context.mounted || choice == null) return;
  if (choice == '__none__') {
    await takes.clearProject(take);
  } else {
    await takes.assignToProject(take, choice);
  }
}

Future<void> _confirmDelete(BuildContext context, Takes takes, Take take) async {
  final title = takes.titleFor(take) ?? take.humanDate;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Tokens.surface,
      title: Text('Delete this take?', style: Tokens.title),
      content: Text(
        '$title\n${take.meta}\n\nIt is removed from this device, with its transcript and summary.',
        style: Tokens.bodySmall,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Keep')),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: Tokens.danger,
            foregroundColor: Tokens.onAccent,
          ),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (ok == true) await takes.delete(take);
}
