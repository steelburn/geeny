import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../ai/ai_client.dart';
import '../ai/ai_settings.dart';
import '../ai/notes.dart';

/// One pulled recording on disk.
class Take {
  Take({required this.file, required this.bytes, required this.modified, this.duration = Duration.zero});

  final File file;
  final int bytes;
  final DateTime modified;
  final Duration duration;

  /// `MM:SS`, or `--:--` if the file has no readable Ogg granule.
  String get length => duration == Duration.zero
      ? '--:--'
      : '${duration.inMinutes.toString().padLeft(2, '0')}:'
          '${(duration.inSeconds % 60).toString().padLeft(2, '0')}';

  String get name => file.uri.pathSegments.last;

  String get size =>
      bytes < 1024 ? '$bytes B' : '${(bytes / 1024).toStringAsFixed(1)} kB';

  String get meta => '$length · $size';

  /// '11 Nov · 05:48' — a label a person reads, used when a take has no title.
  String get humanDate {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final d = modified;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.day} ${months[d.month - 1]} · ${two(d.hour)}:${two(d.minute)}';
  }

  /// Ogg Opus length from the last page's granule position (16 kHz).
  static Duration readDuration(File file) {
    try {
      final bytes = file.readAsBytesSync();
      var lastGranule = 0;
      var i = 0;
      while (true) {
        final idx = _findOggS(bytes, i);
        if (idx < 0 || idx + 27 > bytes.length) break;
        final granule = bytes[idx + 6] |
            (bytes[idx + 7] << 8) |
            (bytes[idx + 8] << 16) |
            (bytes[idx + 9] << 24);
        if (granule > lastGranule) lastGranule = granule;
        final nseg = bytes[idx + 26];
        var body = 0;
        for (var k = 0; k < nseg && idx + 27 + k < bytes.length; k++) {
          body += bytes[idx + 27 + k];
        }
        i = idx + 27 + nseg + body;
      }
      if (lastGranule <= 0) return Duration.zero;
      return Duration(milliseconds: (lastGranule / 16).round());
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
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.ogg'))
          .toList()
        ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      items = files
          .map((f) => Take(
                file: f,
                bytes: f.lengthSync(),
                modified: f.lastModifiedSync(),
                duration: Take.readDuration(f),
              ))
          .toList();
      // Transcripts and summaries survive a restart: they live next to the take.
      for (final f in files) {
        if (notes.containsKey(f.path)) continue;
        final restored = _loadNotes(f);
        if (restored != null) notes[f.path] = restored;
      }
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
    await _saveIndex();
    await refresh();
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
