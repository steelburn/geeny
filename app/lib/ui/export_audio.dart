import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../state/takes.dart';

/// A file name a person can recognise, from a title or a take name.
///
/// Titles are model output (and typed by hand), so anything that is not a letter,
/// digit, space, dot, dash or underscore goes — including path separators, which
/// would otherwise let a title decide where a file lands.
String safeFileName(String title, {int maxLength = 60}) {
  var name = title
      .replaceAll(RegExp(r'[^\p{L}\p{N} ._-]+', unicode: true), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      // No hidden files and no `..` component, whatever the title tried.
      .replaceAll(RegExp(r'\.{2,}'), '.')
      .replaceAll(RegExp(r'^[.\s]+'), '')
      .replaceAll(RegExp(r'[.\s]+$'), '')
      .trim();
  if (name.length > maxLength) name = name.substring(0, maxLength).trimRight();
  return name.isEmpty ? 'take' : name;
}

/// The audio container a take is in, as a mime type for the share sheet.
String audioMimeFor(String path) {
  final ext = path.split('.').last.toLowerCase();
  return switch (ext) {
    'ogg' || 'oga' || 'opus' => 'audio/ogg',
    'mp3' => 'audio/mpeg',
    'm4a' || 'mp4' || 'aac' => 'audio/mp4',
    'wav' => 'audio/wav',
    'flac' => 'audio/flac',
    _ => 'audio/*',
  };
}

/// Save or share a take's recording through the system sheet.
///
/// The file is copied to the cache under its *title* first: `notra-2026-11-11T1234.ogg`
/// tells nobody anything, while the title is what the take is called everywhere
/// else in the app. The original stays untouched in the library — this is a
/// copy, so an export can never lose the recording.
Future<void> exportTakeAudio(BuildContext context, Takes takes, Take take) async {
  if (!take.hasAudio) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('This take has no audio here — it stayed in Boya OS.'),
        duration: Duration(seconds: 3),
      ),
    );
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  try {
    // An untitled take is named after its date, with the clock's colon turned
    // into a dot: `:` is not a legal character in a file name on every system
    // this file might land on.
    final title = takes.titleFor(take) ??
        take.humanDate.replaceAll('·', '').replaceAll(':', '.').replaceAll(RegExp(r'\s+'), ' ').trim();
    final ext = take.file.path.split('.').last.toLowerCase();
    final dir = await getTemporaryDirectory();
    final copy = File('${dir.path}/${safeFileName(title)}.$ext');
    await take.file.copy(copy.path);
    await SharePlus.instance.share(ShareParams(
      files: [XFile(copy.path, mimeType: audioMimeFor(take.file.path))],
      text: title,
    ));
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Could not export this recording: $e')),
    );
  }
}
