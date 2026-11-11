import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../ai/ai_client.dart';
import '../ai/ai_settings.dart';
import '../ai/ask.dart';
import '../ai/notes.dart';
import '../import/boya_import.dart';
import '../import/share_in.dart';

/// One pulled recording on disk, or an imported transcript without audio.
class Take {
  Take({
    required this.file,
    required this.bytes,
    required this.modified,
    this.duration = Duration.zero,
    this.hasAudio = true,
  });

  final File file;
  final int bytes;
  final DateTime modified;
  final Duration duration;

  /// False for a transcript imported from Boya OS when its audio stayed there.
  /// Everything reading a take must check this before playing it.
  final bool hasAudio;

  /// `MM:SS`, or `--:--` if the file has no readable Ogg granule.
  String get length => duration == Duration.zero
      ? '--:--'
      : '${duration.inMinutes.toString().padLeft(2, '0')}:'
          '${(duration.inSeconds % 60).toString().padLeft(2, '0')}';

  String get name => file.uri.pathSegments.last;

  String get size =>
      bytes < 1024 ? '$bytes B' : '${(bytes / 1024).toStringAsFixed(1)} kB';

  String get meta => hasAudio ? '$length · $size' : 'transcript only';

  /// '11 Nov · 05:48' — a label a person reads, used when a take has no title.
  String get humanDate {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final d = modified;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.day} ${months[d.month - 1]} · ${two(d.hour)}:${two(d.minute)}';
  }

  /// Ogg Opus length from the last page's granule position (16 kHz).
  ///
  /// Ogg defines the duration by the final page, not by the largest granule: one
  /// damaged or odd page in the middle can carry a nonsense value, and taking the
  /// maximum would report a 48 s take as three hours.
  static Duration readDuration(File file) {
    try {
      final bytes = file.readAsBytesSync();
      var lastGranule = 0;
      var maxGranule = 0;
      var seen = 0;
      var i = 0;
      while (true) {
        final idx = _findOggS(bytes, i);
        if (idx < 0 || idx + 27 > bytes.length) break;
        final granule = bytes[idx + 6] |
            (bytes[idx + 7] << 8) |
            (bytes[idx + 8] << 16) |
            (bytes[idx + 9] << 24);
        if (granule > maxGranule) maxGranule = granule;
        lastGranule = granule;
        seen++;
        final nseg = bytes[idx + 26];
        var body = 0;
        for (var k = 0; k < nseg && idx + 27 + k < bytes.length; k++) {
          body += bytes[idx + 27 + k];
        }
        i = idx + 27 + nseg + body;
      }
      if (seen == 0) return Duration.zero;
      final use = lastGranule > 0 ? lastGranule : maxGranule;
      if (use <= 0) return Duration.zero;
      return Duration(milliseconds: (use / 16).round());
    } catch (_) {
      return Duration.zero;
    }
  }

  static int _findOggS(List<int> b, int from) {
    for (var i = from; i + 4 <= b.length; i++) {
      if (b[i] == 0x4F && b[i + 1] == 0x67 && b[i + 2] == 0x67 && b[i + 3] == 0x53) return i;
    }
    return -1;
  }

  String get stamp {
    final d = modified;
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}

/// The takes pulled into the app's documents directory, and playback for them.
class Takes extends ChangeNotifier {
  Takes() {
    aiSettings.load();
    _subs.add(_player.positionStream.listen((p) {
      _position = p;
      notifyListeners();
    }));
    _subs.add(_player.durationStream.listen((d) {
      _duration = d ?? Duration.zero;
      notifyListeners();
    }));
    _subs.add(_player.playerStateStream.listen((s) {
      _playing = s.playing && s.processingState != ProcessingState.completed;
      if (s.processingState == ProcessingState.completed) {
        _position = _duration;
      }
      notifyListeners();
    }));
    refresh();
    _drainShares();
  }

  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription<dynamic>> _subs = [];
  final AiSettings aiSettings = AiSettings();
  late AiClient ai = AiClient(aiSettings);

  /// Transcripts/summaries by take path.
  final Map<String, TakeNotes> notes = {};
  String? aiError;
  String? working;      // path currently being transcribed
  String? aiService;    // null = reachable, string = reason it is not

  /// A one-line result of the last import, shown above the list until dismissed.
  String? notice;
  bool importing = false;

  /// Search index bookkeeping: `_notesRevision` moves whenever notes change, so a
  /// second open of the Ask sheet does not push the same corpus again.
  int _notesRevision = 0;
  int _indexedRevision = -1;
  int indexedTakes = 0;
  int indexedPassages = 0;
  String? searchError;
  bool indexing = false;

  /// Bumped when a model is removed, so the settings panel re-reads the catalog
  /// instead of offering a model that is no longer on the machine.
  int modelsRevision = 0;

  List<Take> items = [];
  Take? current;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  String? error;
  String filter = 'all';
  List<String> projects = [];
  final Map<String, String> titles = {};
  final Map<String, String> projectOf = {};
  File? _indexFile;

  Duration get position => _position;
  Duration get duration => _duration;
  bool get isPlaying => _playing;

  static String clock(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  /// Check whether the local AI service is up (cheap, cached by the service).
  Future<String?> probeAi() async {
    aiService = await ai.probe();
    notifyListeners();
    return aiService;
  }

  /// Transcribe and/or summarise a take, doing only the work that is missing.
  ///
  /// An existing transcript is never re-run just because the notes sheet was
  /// opened again, and an existing summary is never re-generated for the same
  /// template. `force` is the one path that repeats both (the Redo button).
  Future<TakeNotes?> generateNotes(Take take,
      {String template = 'meeting', bool force = false}) async {
    if (working != null) return null;
    final existing = notes[take.file.path];
    final action = notesAction(notes: existing, template: template, force: force);
    if (action == NotesAction.none) return existing;

    working = take.file.path;
    aiError = null;
    notifyListeners();
    try {
      var parsed = existing;
      if (action == NotesAction.transcribeAndSummarize) {
        final transcript = await ai.transcribe(take.file);
        parsed = TakeNotes.fromJson(take.file.path, transcript);
        parsed.template = template;
        notes[take.file.path] = parsed;
        await _saveNotes(take, parsed);
        notifyListeners();
        if (titles[take.file.path] == null) {
          await generateTitle(take, parsed.transcriptJson);
        }
      }
      final notesForTake = parsed!;
      final summary = await ai.summarize(notesForTake.transcriptJson, template: template);
      notesForTake.summary = summary;
      notesForTake.template = template;
      await _saveNotes(take, notesForTake);
      notifyListeners();
      return notesForTake;
    } catch (e) {
      aiError = e.toString().replaceFirst('Exception: ', '');
      return null;
    } finally {
      working = null;
      notifyListeners();
    }
  }

  /// Re-run only the summary (e.g. after switching template). The transcript is
  /// reused as-is.
  Future<void> resummarize(Take take, String template) async {
    final parsed = notes[take.file.path];
    if (parsed == null) return;
    working = take.file.path;
    aiError = null;
    notifyListeners();
    try {
      parsed.summary = await ai.summarize(parsed.transcriptJson, template: template);
      parsed.template = template;
      await _saveNotes(take, parsed);
    } catch (e) {
      aiError = e.toString().replaceFirst('Exception: ', '');
    } finally {
      working = null;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _indexFile ??= File('${dir.path}/library.json');
      await _loadIndex();
      final files = dir.listSync().whereType<File>().toList();
      final audio = files
          .where((f) => f.path.toLowerCase().endsWith('.ogg'))
          .toList()
        ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      final audioPaths = {for (final f in audio) f.path};

      final loaded = audio
          .map((f) => Take(
                file: f,
                bytes: f.lengthSync(),
                modified: f.lastModifiedSync(),
                duration: Take.readDuration(f),
              ))
          .toList();

      // A transcript imported from Boya OS has no audio beside it: the sidecar is
      // the take. It is still listed, searchable and readable — just not playable.
      for (final sidecar in files.where((f) => f.path.endsWith('.notes.json'))) {
        final takePath = sidecar.path.substring(0, sidecar.path.length - '.notes.json'.length);
        if (audioPaths.contains(takePath)) continue;
        loaded.add(Take(
          file: File(takePath),
          bytes: 0,
          modified: sidecar.lastModifiedSync(),
          hasAudio: false,
        ));
      }
      loaded.sort((a, b) => b.modified.compareTo(a.modified));
      items = loaded;

      // Transcripts and summaries survive a restart: they live next to the take.
      for (final take in items) {
        if (notes.containsKey(take.file.path)) continue;
        final restored = _loadNotes(take.file);
        if (restored != null) notes[take.file.path] = restored;
      }
      _notesRevision++;
      error = null;
    } catch (e) {
      error = 'Could not list takes: $e';
    }
    notifyListeners();
  }

  /// Sidecar path for a take's transcript/summary (`<take>.notes.json`).
  static File notesFileFor(File takeFile) => File('${takeFile.path}.notes.json');
  TakeNotes? _loadNotes(File takeFile) {
    try {
      final f = notesFileFor(takeFile);
      if (!f.existsSync()) return null;
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final notesForTake = TakeNotes.fromJson(takeFile.path, json);
      return notesForTake.hasTranscript ? notesForTake : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveNotes(Take take, TakeNotes value) async {
    try {
      await notesFileFor(take.file).writeAsString(jsonEncode(value.toJson()));
      _notesRevision++;
    } catch (e) {
      // A read-only library is not worth failing the notes over; keep them in memory.
      debugPrint('could not save notes for ${take.name}: $e');
    }
  }

  Future<void> _loadIndex() async {
    try {
      final f = _indexFile;
      if (f == null) return;
      var source = f;
      if (!source.existsSync()) {
        // earlier builds kept only projects; migrate it in place
        final legacy = File('${f.parent.path}/projects.json');
        if (!legacy.existsSync()) return;
        source = legacy;
      }
      final data = jsonDecode(source.readAsStringSync()) as Map<String, dynamic>;
      projects = [for (final p in (data['projects'] as List? ?? const [])) p.toString()];
      projectOf
        ..clear()
        ..addAll({for (final e in (data['assignments'] as Map? ?? {}).entries) e.key.toString(): e.value.toString()});
      titles
        ..clear()
        ..addAll({for (final e in (data['titles'] as Map? ?? {}).entries) e.key.toString(): e.value.toString()});
    } catch (_) {
      // a corrupt index is not worth failing the library over
    }
  }

  Future<void> _saveIndex() async {
    final f = _indexFile;
    if (f == null) return;
    f.writeAsStringSync(jsonEncode({
      'projects': projects,
      'assignments': projectOf,
      'titles': titles,
    }));
  }

  /// Create (or reuse) a project and put this take in it.
  Future<void> assignToProject(Take take, String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    if (!projects.contains(clean)) projects.add(clean);
    projectOf[take.file.path] = clean;
    await _saveIndex();
    notifyListeners();
  }

  Future<void> clearProject(Take take) async {
    projectOf.remove(take.file.path);
    await _saveIndex();
    notifyListeners();
  }

  void setFilter(String f) {
    filter = f;
    notifyListeners();
  }

  /// Takes after the project filter. `unfiled` = no project yet, so "All" is never
  /// the only way to tell things apart.
  List<Take> get visible => filterTakes(items, projectOf, filter);

  int get unfiledCount => items.where((t) => projectOf[t.file.path] == null).length;

  /// Human title for a take, when one has been generated or typed.
  String? titleFor(Take take) => titles[take.file.path];

  Future<void> setTitle(Take take, String title) async {
    final clean = title.trim();
    if (clean.isEmpty) {
      titles.remove(take.file.path);
    } else {
      titles[take.file.path] = clean;
    }
    _notesRevision++;
    await _saveIndex();
    notifyListeners();
  }

  /// Ask the service for a title, only when there is enough to work with.
  Future<String?> generateTitle(Take take, Map<String, dynamic> transcriptJson) async {
    final words = [for (final s in (transcriptJson['segments'] as List? ?? const [])) s['text']]
        .join(' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .length;
    if (words < 8) return null;
    final title = await ai.title(transcriptJson);
    if (title != null && title.isNotEmpty) await setTitle(take, title);
    return title;
  }

  /// Remove a take from disk (and its notes), stopping playback if needed.
  Future<void> delete(Take take) async {
    if (current?.file.path == take.file.path) {
      await _player.stop();
      current = null;
      _position = Duration.zero;
      _duration = Duration.zero;
    }
    try {
      if (take.file.existsSync()) take.file.deleteSync();
      final sidecar = notesFileFor(take.file);
      if (sidecar.existsSync()) sidecar.deleteSync();
    } catch (e) {
      error = 'Could not delete ${take.name}: $e';
    }
    notes.remove(take.file.path);
    projectOf.remove(take.file.path);
    titles.remove(take.file.path);
    _notesRevision++;
    await _saveIndex();
    await refresh();
  }

  /// The take a search hit or an answer source points at.
  Take? takeForId(String id) {
    for (final take in items) {
      if (take.file.path == id || take.name == id) return take;
    }
    return null;
  }

  /// Load a take into the player and park it at [to] without starting playback.
  ///
  /// Used when a search hit is opened: the transcript is the point, and playing
  /// audio nobody asked for is not.
  Future<void> cue(Take take, Duration to) async {
    if (!take.hasAudio) return;
    if (current?.file.path != take.file.path) {
      try {
        await _player.setFilePath(take.file.path);
        current = take;
        _position = Duration.zero;
        _duration = Duration.zero;
      } catch (e) {
        error = 'Cannot open ${take.name}: $e';
        notifyListeners();
        return;
      }
    }
    await _player.seek(to);
    notifyListeners();
  }

  Future<void> toggle(Take take) async {
    if (current?.file.path == take.file.path) {
      if (_playing) {
        await _player.pause();
      } else {
        if (_player.processingState == ProcessingState.completed) {
          await _player.seek(Duration.zero);
        }
        await _player.play();
      }
      return;
    }
    await play(take);
  }

  Future<void> play(Take take) async {
    if (!take.hasAudio) {
      notice = 'This is a transcript only — its audio stayed in Boya OS.';
      notifyListeners();
      return;
    }
    try {
      error = null;
      current = take;
      _position = Duration.zero;
      _duration = Duration.zero;
      notifyListeners();
      await _player.setFilePath(take.file.path);
      await _player.play();
    } catch (e) {
      error = 'Cannot play ${take.name}: $e';
      current = null;
      notifyListeners();
    }
  }

  Future<void> seek(Duration to) async {
    if (current == null) return;
    await _player.seek(to);
  }

  // --- search and ask -------------------------------------------------------

  /// The corpus the local service indexes: transcripts + summaries + labels.
  /// The audio itself is not sent anywhere; text only, and only to your own
  /// machine.
  List<Map<String, dynamic>> searchDocuments() {
    final out = <Map<String, dynamic>>[];
    for (final take in items) {
      final note = notes[take.file.path];
      if (note == null || !note.hasTranscript) continue;
      out.add({
        'id': take.file.path,
        'title': titles[take.file.path] ?? take.humanDate,
        'date': take.humanDate,
        'project': projectOf[take.file.path] ?? '',
        'duration': note.duration,
        'segments': [
          for (final s in note.segments)
            {
              'start': s.start,
              'end': s.end,
              'text': s.text,
              if (s.speaker != null) 'speaker': s.speaker,
            }
        ],
        'summary': note.summary ?? const {},
      });
    }
    return out;
  }

  /// Push the corpus when it has changed since the last push, or when the service
  /// no longer holds it (a restarted service starts with an empty index).
  Future<bool> syncSearchIndex({bool force = false}) async {
    final documents = searchDocuments();
    final unchanged = !force && _indexedRevision == _notesRevision && indexedTakes == documents.length;
    if (unchanged) {
      final state = await ai.indexState();
      if (state != null && (state['documents'] as num?)?.toInt() == documents.length) {
        indexedPassages = (state['passages'] as num?)?.toInt() ?? indexedPassages;
        return true;
      }
    }
    indexedTakes = documents.length;
    if (documents.isEmpty) {
      indexedPassages = 0;
      _indexedRevision = _notesRevision;
      searchError = null;
      notifyListeners();
      return true;
    }
    indexing = true;
    searchError = null;
    notifyListeners();
    try {
      final state = await ai.indexDocuments(documents);
      if (state == null) {
        searchError = 'The local AI service is not answering. Search runs there.';
        return false;
      }
      indexedPassages = (state['passages'] as num?)?.toInt() ?? 0;
      indexedTakes = (state['documents'] as num?)?.toInt() ?? documents.length;
      _indexedRevision = _notesRevision;
      return true;
    } finally {
      indexing = false;
      notifyListeners();
    }
  }

  Future<List<AskHit>> searchNotes(String query, {int limit = 12}) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    await syncSearchIndex();
    try {
      return await ai.search(q, limit: limit);
    } catch (e) {
      searchError = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
      return [];
    }
  }

  /// A written answer over the notes. Null when nothing in the library matches.
  Future<AskAnswer?> askNotes(String question) async {
    final q = question.trim();
    if (q.isEmpty) return null;
    await syncSearchIndex();
    try {
      return await ai.ask(q);
    } catch (e) {
      searchError = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
      return null;
    }
  }

  void dismissSearchError() {
    searchError = null;
    notifyListeners();
  }

  // --- import (Boya OS share / export) -------------------------------------

  /// The background room: a share that launches the app, and shares that arrive
  /// while it is open.
  Future<void> _drainShares() async {
    ShareIn.listen((file) => importShared(file));
    final file = await ShareIn.initial();
    if (file != null) await importShared(file);
  }

  /// Import whatever the share sheet (or the picker) handed over.
  ///
  /// Audio becomes a normal take; a transcript export is attached to the take it
  /// names, or kept on its own when the audio is not here.
  Future<void> importShared(SharedFile file) async {
    if (importing) return;
    importing = true;
    notice = null;
    notifyListeners();
    try {
      if (file.isText) {
        final content = File(file.path).readAsStringSync();
        final parsed = parseExport(content, sourceName: file.name);
        if (parsed == null) {
          notice = 'Could not read ${file.name}. Export the transcript as TXT, Markdown, '
              'SRT or JSON and share it again.';
          return;
        }
        notice = await importNote(parsed, sourceName: file.name);
      } else if (file.isAudio) {
        notice = await importAudio(file);
      } else {
        notice = '${file.name} is not a recording or a transcript export. Boya OS can export '
            'audio (Ogg, MP3, WAV) and its transcript as TXT, Markdown, SRT, DOCX or PDF.';
      }
    } catch (e) {
      notice = 'Import failed: ${e.toString().replaceFirst('Exception: ', '')}';
    } finally {
      importing = false;
      notifyListeners();
    }
  }

  /// Open the system picker, then import the choice.
  Future<void> importFromPicker() async {
    final file = await ShareIn.pick();
    if (file != null) await importShared(file);
  }

  /// Copy an exported recording into the library under its own name.
  Future<String> importAudio(SharedFile file) async {
    final dir = await getApplicationDocumentsDirectory();
    final source = File(file.path);
    final stem = _stem(file.name).replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();
    final base = stem.isEmpty ? 'boya' : stem.substring(0, stem.length.clamp(0, 60));
    final size = source.lengthSync();
    for (final take in items.where((t) => t.hasAudio)) {
      if (take.bytes == size && _stem(take.name) == base) {
        return '"${take.name}" is already in the library.';
      }
    }
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '').substring(0, 15);
    final ext = switch (file.extension) {
      'opus' || 'oga' => 'ogg',
      '' => 'ogg',
      _ => file.extension,
    };
    final dest = File('${dir.path}/boya-$base-$stamp.$ext');
    await source.copy(dest.path);
    await refresh();
    final playable = ext == 'ogg';
    return 'Imported ${file.name} as ${dest.uri.pathSegments.last}.'
        '${playable ? '' : ' It plays, but the local service transcribes Ogg Opus — export '
              'the recording as Ogg in Boya OS if you want notes.'}';
  }

  /// Attach a parsed transcript/summary to a take, or create a transcript-only
  /// take when its recording stayed in Boya OS.
  Future<String> importNote(ImportedNote parsed, {String sourceName = ''}) async {
    final stem = _stem(sourceName);
    Take? target;
    if (stem.isNotEmpty) {
      for (final take in items) {
        if (_stem(take.name).toLowerCase() == stem.toLowerCase()) target = take;
      }
    }
    final wanted = parsed.title.trim().toLowerCase();
    if (target == null && wanted.isNotEmpty) {
      for (final take in items) {
        if ((titles[take.file.path] ?? '').toLowerCase() == wanted) target = take;
      }
    }

    if (target == null) {
      final dir = await getApplicationDocumentsDirectory();
      final slug = (parsed.title.trim().isEmpty ? stem : parsed.title)
          .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
          .trim()
          .replaceAll(RegExp(r'\s+'), '-');
      final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '').substring(0, 15);
      final base = slug.isEmpty ? 'imported' : slug.substring(0, slug.length.clamp(0, 48));
      final path = '${dir.path}/imported-$base-$stamp.ogg';
      final notesForTake = parsed.toNotes(path);
      await notesFileFor(File(path)).writeAsString(jsonEncode(notesForTake.toJson()));
      if (parsed.title.trim().isNotEmpty) titles[path] = parsed.title.trim();
      _notesRevision++;
      await _saveIndex();
      await refresh();
      return 'Imported “${parsed.title.trim().isEmpty ? fileLabel(path) : parsed.title.trim()}” '
          'as a transcript-only take — the audio stayed in Boya OS. It is searchable, '
          'readable and exportable like any other take.';
    }

    final existing = notes[target.file.path];
    final incoming = parsed.toNotes(target.file.path);
    if (!incoming.hasTranscript && existing != null) {
      // A summary-only export keeps the transcript this take already has.
      incoming.segments.addAll(existing.segments);
    }
    notes[target.file.path] = incoming;
    await _saveNotes(target, incoming);
    if (parsed.title.trim().isNotEmpty && titles[target.file.path] == null) {
      titles[target.file.path] = parsed.title.trim();
      await _saveIndex();
    }
    notifyListeners();
    return 'Attached the imported ${parsed.hasSummary ? 'transcript and summary' : 'transcript'} '
        'to ${target.name}.';
  }

  void dismissNotice() {
    notice = null;
    notifyListeners();
  }

  static String _stem(String name) {
    final base = name.split(RegExp(r'[\\/]')).last;
    final dot = base.lastIndexOf('.');
    return (dot > 0 ? base.substring(0, dot) : base).trim();
  }

  static String fileLabel(String path) => path.split(RegExp(r'[\\/]')).last;

  /// Remove a downloaded model from the serving machine.
  ///
  /// If it was the selected summary model the setting falls back to the service
  /// default, so the next summary does not fail on a model that is gone.
  Future<({int freed, String? error})> deleteModel(String kind, String name) async {
    final result = await ai.deleteModel(kind, name);
    if (result.error == null) {
      modelsRevision++;
      if (kind == 'summary' && aiSettings.localSummary == name) {
        aiSettings.setLocalSummary('auto');
      }
    }
    notifyListeners();
    return result;
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}


/// Pure filter used by the Takes list: `all`, `unfiled`, or a project name.
List<Take> filterTakes(List<Take> items, Map<String, String> projectOf, String filter) =>
    switch (filter) {
      'all' => items,
      'unfiled' => items.where((t) => projectOf[t.file.path] == null).toList(),
      _ => items.where((t) => projectOf[t.file.path] == filter).toList(),
    };
