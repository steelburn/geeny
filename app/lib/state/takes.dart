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
import '../ai/search_index.dart';
import '../import/boya_import.dart';
import '../import/share_in.dart';
import 'audio_duration.dart';

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

  /// False for an import from Boya OS when its audio stayed there. It then holds
  /// a transcript, a summary or both. Everything reading a take must check this
  /// before playing it.
  final bool hasAudio;

  /// The formats the library lists: the ones the share sheet and picker accept
  /// (`SharedFile.audioExtensions`). The recorder writes `.ogg`; an import from
  /// Boya OS can arrive as any of them, and a set that disagreed with the import
  /// dropped the copy it had just made.
  static const audioExtensions = SharedFile.audioExtensions;

  static bool isAudioPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return false;
    return audioExtensions.contains(path.substring(dot + 1).toLowerCase());
  }

  static String extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  }

  /// The take that already holds exactly this recording, if any.
  ///
  /// The stored name is not the shared one (`boya-<name>-<stamp>.mp3`), so
  /// matching stems — what this used to do — never fired and a second import of
  /// the same recording made a second copy. Size comes from the index first,
  /// which is cheap; only takes that are the same size are read and compared,
  /// so a duplicate is decided by the bytes rather than by a name that a rename
  /// or a re-export can change.
  static Take? findByContent(List<Take> takes, File source) {
    try {
      if (!source.existsSync()) return null;
      final size = source.lengthSync();
      final candidates = takes.where((t) => t.hasAudio && t.bytes == size).toList();
      if (candidates.isEmpty) return null;
      final incoming = source.readAsBytesSync();
      for (final take in candidates) {
        try {
          if (_sameBytes(take.file.readAsBytesSync(), incoming)) return take;
        } catch (_) {
          // A take that cannot be read now cannot be this duplicate.
        }
      }
    } catch (_) {
      // Unreadable share: let the copy fail loudly rather than guess.
    }
    return null;
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// `MM:SS`, or `--:--` if the container's length cannot be read without a
  /// decoder (M4A/AAC/AMR).
  String get length => duration == Duration.zero
      ? '--:--'
      : '${duration.inMinutes.toString().padLeft(2, '0')}:'
          '${(duration.inSeconds % 60).toString().padLeft(2, '0')}';

  String get name => file.uri.pathSegments.last;

  String get size =>
      bytes < 1024 ? '$bytes B' : '${(bytes / 1024).toStringAsFixed(1)} kB';

  String get meta => hasAudio ? '$length · $size' : 'notes only';

  /// '11 Nov · 05:48' — a label a person reads, used when a take has no title.
  String get humanDate {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final d = modified;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.day} ${months[d.month - 1]} · ${two(d.hour)}:${two(d.minute)}';
  }

  /// Length by container: Ogg granule (48 kHz), WAV byte rate, FLAC STREAMINFO
  /// or MP3 frames. See `audio_duration.dart` for the per-format details.
  static Duration readDuration(File file) {
    try {
      return audioDuration(file.readAsBytesSync(), extensionOf(file.path)) ??
          Duration.zero;
    } catch (_) {
      return Duration.zero;
    }
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
  /// second open of the Ask sheet does not rebuild the same corpus again.
  int _notesRevision = 0;
  int _indexedRevision = -1;
  int indexedTakes = 0;
  int indexedPassages = 0;
  String? searchError;

  /// The index search actually reads. It lives here, on the device, so Search and
  /// Ask keep working when no AI service (and no network) is available.
  final SearchIndex _index = SearchIndex();

  /// The last background push to the machine's copy of the index, so an answer
  /// written by the machine does not race the corpus it answers from.
  Future<void>? _indexPush;

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

  /// The name each imported take arrived under (`Field notes (Recording).mp3`).
  ///
  /// The file on disk is stored under Geeny's own `boya-…` name, so this is what
  /// lets a later export of the same meeting — same name, a different kind
  /// suffix — find the take it belongs to instead of becoming a second one.
  final Map<String, String> sources = {};

  /// Takes whose title was asked for in this session, so a model that answers
  /// with nothing does not get asked again on every open.
  final Set<String> _titleAttempted = {};
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
    // A take imported without its audio has nothing to transcribe: its file is
    // the sidecar, and its transcript/summary is all there is. Leave it alone.
    if (!take.hasAudio) return existing;
    final action = notesAction(notes: existing, template: template, force: force);
    if (action == NotesAction.none) return existing;

    working = take.file.path;
    aiError = null;
    notifyListeners();
    try {
      var parsed = existing;
      if (action == NotesAction.transcribeAndSummarize) {
        // The languages the person declared before the first run, remembered
        // in preferences across sessions. Empty means "detect".
        final transcript = await ai.transcribe(
          take.file,
          languages: aiSettings.speechLanguages,
        );
        parsed = TakeNotes.fromJson(take.file.path, transcript);
        parsed.template = template;
        notes[take.file.path] = parsed;
        await _saveNotes(take, parsed);
        notifyListeners();
      }
      final notesForTake = parsed!;
      final summary = await ai.summarize(notesForTake.transcriptJson, template: template);
      notesForTake.summary = summary;
      notesForTake.template = template;
      await _saveNotes(take, notesForTake);
      // A take whose title never landed (a summary-only run, an older build, a
      // model that answered "null") gets one here, not only after transcription.
      if (titles[take.file.path] == null) {
        await generateTitle(take, notesForTake.transcriptJson);
      }
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
      // Every container the import accepts, not only the recorder's Ogg: an MP3
      // shared from Boya OS is a normal take too.
      final audio = files
          .where((f) => Take.isAudioPath(f.path))
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
      // A summary exported without its transcript is still notes, and it is what
      // Group has to work with when the transcript stayed in Boya OS.
      return notesForTake.hasTranscript || notesForTake.hasSummary ? notesForTake : null;
    } catch (_) {
      return null;
    }
  }

  /// The notes this take has, from memory or from its sidecar.
  TakeNotes? _notesFor(Take take) =>
      notes[take.file.path] ?? _loadNotes(take.file);

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
        ..addAll({
          for (final e in (data['titles'] as Map? ?? {}).entries)
            if (cleanTitle(e.value.toString()) != null)
              e.key.toString(): cleanTitle(e.value.toString())!,
        });
      sources
        ..clear()
        ..addAll({
          for (final e in (data['sources'] as Map? ?? {}).entries)
            if (e.value.toString().trim().isNotEmpty) e.key.toString(): e.value.toString(),
        });
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
      'sources': sources,
    }));
  }

  /// Create (or reuse) a project and put this take in it.
  Future<void> assignToProject(Take take, String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    if (!projects.contains(clean)) projects.add(clean);
    projectOf[take.file.path] = clean;
    _notesRevision++;
    await _saveIndex();
    notifyListeners();
  }

  Future<void> clearProject(Take take) async {
    projectOf.remove(take.file.path);
    _notesRevision++;
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
  ///
  /// A title saved by an older build may be junk the model's answer was taken at
  /// face value (`"null"` is in real libraries); [cleanTitle] filters it here too,
  /// so a bad entry reads as untitled instead of as a title.
  String? titleFor(Take take) => cleanTitle(titles[take.file.path]);

  Future<void> setTitle(Take take, String title) async {
    final clean = cleanTitle(title);
    if (clean == null) {
      titles.remove(take.file.path);
    } else {
      titles[take.file.path] = clean;
    }
    _notesRevision++;
    await _saveIndex();
    notifyListeners();
  }

  /// Ask the service for a title, only when there is enough to work with.
  ///
  /// One attempt per take per session: a model that answers with nothing must not
  /// turn every glance at the notes into another billed request.
  Future<String?> generateTitle(Take take, Map<String, dynamic> transcriptJson) async {
    final words = [for (final s in (transcriptJson['segments'] as List? ?? const [])) s['text']]
        .join(' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .length;
    if (words < 8) return null;
    if (_titleAttempted.contains(take.file.path)) return titles[take.file.path];
    _titleAttempted.add(take.file.path);
    final title = cleanTitle(await ai.title(transcriptJson));
    if (title != null) await setTitle(take, title);
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
    sources.remove(take.file.path);
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
      notice = 'This take has no audio here — it stayed in Boya OS.';
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

  /// Stop playback and drop the player bar (closing it is a deliberate act).
  Future<void> stop() async {
    await _player.stop();
    current = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    notifyListeners();
  }

  // --- search and ask -------------------------------------------------------

  /// The corpus search reads: transcripts + summaries + labels. It never leaves
  /// the device — the index below is built from this in memory.
  List<Map<String, dynamic>> searchDocuments() {
    final out = <Map<String, dynamic>>[];
    for (final take in items) {
      final note = notes[take.file.path];
      // A summary exported without its transcript is still notes, and still
      // worth finding: search indexes whichever half the take has.
      if (note == null || (!note.hasTranscript && !note.hasSummary)) continue;
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

  /// Rebuild the in-app index when the notes have changed since the last build.
  ///
  /// Search runs on the phone, so nothing here waits for the AI service: the
  /// index is rebuilt from the library in memory, and the machine's copy is
  /// refreshed in the background so the CLI and a machine-side answer see the
  /// same corpus. A failure there no longer breaks search.
  Future<bool> syncSearchIndex({bool force = false}) async {
    final documents = searchDocuments();
    if (!force && _indexedRevision == _notesRevision) {
      indexedTakes = _index.documentCount;
      indexedPassages = _index.passageCount;
      return true;
    }
    _index.replace(documents);
    _indexedRevision = _notesRevision;
    indexedTakes = _index.documentCount;
    indexedPassages = _index.passageCount;
    searchError = null;
    notifyListeners();
    // Best effort: the service's `/chat` answers from its own copy, so it is kept
    // in step when one is running, and silently skipped when none is.
    _indexPush = ai.indexDocuments(documents).then((_) {});
    return true;
  }

  Future<List<AskHit>> searchNotes(String query, {int limit = 12}) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    await syncSearchIndex();
    return _index.search(q, limit: limit);
  }

  /// A written answer over the notes. Null when nothing in the library matches.
  ///
  /// Retrieval is local; [AiClient.answer] asks a model for the prose when one is
  /// configured. Without one the matching passages are the answer, labelled
  /// `extractive` — search never depends on a model or a network existing.
  Future<AskAnswer?> askNotes(String question) async {
    final q = question.trim();
    if (q.isEmpty) return null;
    final hits = await searchNotes(q, limit: 6);
    if (hits.isEmpty) return null;
    searchError = null;
    // The machine writes its answer from its own copy of the index; let the push
    // land first rather than asking against an empty one.
    if (!ai.settings.summaryOnDevice && !ai.settings.summaryExternal) {
      await (_indexPush ?? Future<void>.value());
    }
    try {
      final answer = await ai.answer(q, hits);
      if (answer != null && answer.answer.isNotEmpty) return answer;
    } catch (e) {
      // A model that cannot answer must not take the passages down with it.
      searchError = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
    }
    return extractiveAnswer(hits);
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
  ///
  /// A transcript or summary of the same meeting that was imported first is a
  /// transcript-only take with the same group key; it is folded into the
  /// recording here rather than left behind as a second take. The exports of one
  /// meeting are one take, whatever order they arrive in.
  Future<String> importAudio(SharedFile file) async {
    final dir = await getApplicationDocumentsDirectory();
    final source = File(file.path);
    final stem = _stem(file.name).replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();
    final base = stem.isEmpty ? 'boya' : stem.substring(0, stem.length.clamp(0, 60));
    final duplicate = Take.findByContent(items, source);
    if (duplicate != null) {
      return 'This recording is already in the library as "${duplicate.name}".';
    }
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '').substring(0, 15);
    final ext = switch (file.extension) {
      'opus' || 'oga' => 'ogg',
      '' => 'ogg',
      _ => file.extension,
    };
    final dest = File('${dir.path}/boya-$base-$stamp.$ext');
    await source.copy(dest.path);
    sources[dest.path] = file.name;

    final key = exportGroupKey(file.name);
    final waiting = [
      for (final take in items)
        if (!take.hasAudio && key.isNotEmpty && _groupKeyOf(take) == key) take,
    ];
    await _saveIndex();
    await refresh();

    var grouped = '';
    final recorded = _takeAt(dest.path);
    if (recorded != null && waiting.isNotEmpty) {
      grouped = ' Its ${_kindsLabel([for (final take in waiting) kindOf(take)])} came with it.';
      await _absorb(recorded, waiting);
    }
    final playable = ext == 'ogg';
    return 'Imported ${file.name} as ${dest.uri.pathSegments.last}.$grouped'
        '${playable ? '' : ' It plays, but the local service transcribes Ogg Opus — export '
              'the recording as Ogg in Boya OS if you want notes.'}';
  }

  /// Attach a parsed transcript/summary to a take, or create a take when its
  /// recording stayed in Boya OS.
  ///
  /// The exports of one meeting share a group key: `Sampling walk
  /// (Recording).ogg`, `Sampling walk (Transcript).txt` and `Sampling walk -
  /// Summary.md` are one take. The recording wins as the target, and a
  /// transcript-only take of the same name is extended rather than duplicated.
  Future<String> importNote(ImportedNote parsed, {String sourceName = ''}) async {
    final stem = _stem(sourceName);
    final key = exportGroupKey(sourceName);
    Take? target;
    if (key.isNotEmpty) {
      for (final take in items) {
        if (_groupKeyOf(take) != key) continue;
        // Prefer the recording: a transcript belongs with its audio.
        if (target == null || (take.hasAudio && !target.hasAudio)) target = take;
      }
    }
    final wanted = parsed.title.trim().toLowerCase();
    if (target == null && wanted.isNotEmpty) {
      for (final take in items) {
        if ((titles[take.file.path] ?? '').toLowerCase() != wanted) continue;
        if (target == null || (take.hasAudio && !target.hasAudio)) target = take;
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
      if (sourceName.trim().isNotEmpty) sources[path] = sourceName;
      _notesRevision++;
      await _saveIndex();
      await refresh();
      return 'Imported “${parsed.title.trim().isEmpty ? fileLabel(path) : parsed.title.trim()}” '
          'as a ${parsed.hasTranscript ? 'transcript-only' : 'summary-only'} take — the audio '
          'stayed in Boya OS. It is searchable, readable and exportable like any other take.';
    }

    final existing = _notesFor(target);
    final incoming = parsed.toNotes(target.file.path);
    // The import is authoritative for what it carries: its transcript replaces,
    // a summary-only export keeps the transcript the take already has, and
    // summaries gain the bullets they are missing.
    final merged = combineNotes(target.file.path, [incoming, existing]);
    notes[target.file.path] = merged;
    await _saveNotes(target, merged);
    if (parsed.title.trim().isNotEmpty && titles[target.file.path] == null) {
      titles[target.file.path] = parsed.title.trim();
    }
    if (sourceName.trim().isNotEmpty) {
      sources.putIfAbsent(target.file.path, () => sourceName);
    }
    await _saveIndex();
    notifyListeners();
    final what = parsed.hasTranscript && parsed.hasSummary
        ? 'transcript and summary'
        : parsed.hasSummary
            ? 'summary'
            : 'transcript';
    return 'Attached the imported $what to ${target.name}.';
  }

  // --- groups ---------------------------------------------------------------

  /// What this take brings to a group.
  TakeKind kindOf(Take take) => kindOfTake(hasAudio: take.hasAudio, notes: _notesFor(take));

  /// Put two or three takes of different kinds into the same group.
  ///
  /// A group is one recording and the words about it: its transcript and its
  /// summary. The recording is the take that stays — its audio is what plays —
  /// and the notes-only takes are folded in and removed. Two recordings are two
  /// meetings, so a kind that is already chosen is refused rather than silently
  /// losing a file.
  Future<String> groupTakes(List<Take> selection) async {
    final chosen = <String, Take>{for (final take in selection) take.file.path: take}.values.toList();
    if (chosen.length < 2 || chosen.length > 3) {
      return 'Group two or three takes: a recording, a transcript and a summary.';
    }
    final kinds = <TakeKind>{};
    for (final take in chosen) {
      final kind = kindOf(take);
      if (kind == TakeKind.empty) {
        return '${take.name} has nothing to group yet — no transcript and no summary.';
      }
      if (!kinds.add(kind)) {
        return 'Those include two ${kind.label.toLowerCase()}s. A group holds one of each: '
            'a recording, a transcript, a summary.';
      }
    }
    final target = chosen.firstWhere((t) => t.hasAudio, orElse: () => chosen.first);
    final others = chosen.where((t) => t.file.path != target.file.path).toList();
    final grouped = _kindsLabel([for (final take in others) kindOf(take)]);
    await _absorb(target, others);
    final title = titleFor(target) ?? target.name;
    notice = 'Grouped the $grouped into “$title”.';
    notifyListeners();
    return notice!;
  }

  /// Fold [others] into [target]: their notes become one sidecar on the target,
  /// and the takes that only held those notes are removed.
  ///
  /// Audio is never deleted here — that is the take — so [others] is notes-only
  /// by the time it arrives (both callers check kinds first).
  Future<void> _absorb(Take target, List<Take> others) async {
    final merged = combineNotes(target.file.path, [
      _notesFor(target),
      for (final take in others) _notesFor(take),
    ]);
    notes[target.file.path] = merged;
    await _saveNotes(target, merged);

    for (final take in others) {
      notes.remove(take.file.path);
      sources.remove(take.file.path);
      final project = projectOf.remove(take.file.path);
      if (projectOf[target.file.path] == null && project != null) {
        projectOf[target.file.path] = project;
      }
      if (titles[target.file.path] == null) {
        final inherited = cleanTitle(titles[take.file.path]);
        if (inherited != null) titles[target.file.path] = inherited;
      }
      titles.remove(take.file.path);
      if (take.hasAudio) continue;
      try {
        final sidecar = notesFileFor(take.file);
        if (sidecar.existsSync()) sidecar.deleteSync();
      } catch (e) {
        error = 'Could not remove ${take.name}: $e';
      }
    }
    _notesRevision++;
    await _saveIndex();
    await refresh();
  }

  /// Group key: the original import name when it is known, else the stored name
  /// (old imports carry the same name in their `boya-…`/`imported-…` form).
  String _groupKeyOf(Take take) => exportGroupKey(sources[take.file.path] ?? take.name);

  Take? _takeAt(String path) {
    for (final take in items) {
      if (take.file.path == path) return take;
    }
    return null;
  }

  /// `transcript and summary` — the words for a sentence about a group.
  static String _kindsLabel(Iterable<TakeKind> kinds) {
    final labels = [for (final kind in kinds) kind.label.toLowerCase()];
    if (labels.isEmpty) return 'notes';
    if (labels.length == 1) return labels.first;
    return '${labels.take(labels.length - 1).join(', ')} and ${labels.last}';
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

/// What a take brings to a group.
///
/// A recording carries audio; an import carries words. The kind is what Group
/// checks, so two recordings (two meetings) cannot be folded into one take and
/// a transcript cannot be dropped in place of another transcript.
enum TakeKind {
  recording('Recording'),
  transcript('Transcript'),
  summary('Summary'),
  empty('Nothing yet');

  const TakeKind(this.label);

  final String label;
}

/// The kind of a take, from whether it has audio and what its notes hold.
///
/// A transcript that also carries a summary counts as the transcript: that is
/// what it mostly is, and the summary travels with it when groups are merged.
TakeKind kindOfTake({required bool hasAudio, TakeNotes? notes}) {
  if (hasAudio) return TakeKind.recording;
  if (notes == null) return TakeKind.empty;
  if (notes.hasTranscript) return TakeKind.transcript;
  if (notes.hasSummary) return TakeKind.summary;
  return TakeKind.empty;
}
