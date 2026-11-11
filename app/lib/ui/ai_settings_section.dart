import 'dart:async';

import 'package:flutter/material.dart';

import '../ai/ai_settings.dart';
import '../ai/device/device_models.dart';
import '../ai/languages.dart';
import '../state/takes.dart';
import '../theme/tokens.dart';
import 'choice_chip.dart';
import 'language_picker.dart';

/// Transcription settings. Speech and summary are routed **independently** across
/// three backends — on this device, on this machine (the AI service) or an
/// external service — so on-device whisper with the machine's big summary model
/// (or the other way round) is a normal setup. The local service address is not
/// edited here: the app knows it.
class AiSettingsSection extends StatefulWidget {
  const AiSettingsSection({super.key, required this.takes});
  final Takes takes;

  @override
  State<AiSettingsSection> createState() => _AiSettingsSectionState();
}

class _AiSettingsSectionState extends State<AiSettingsSection> {
  late final AiSettings s = widget.takes.aiSettings;
  late final TextEditingController _extUrl;
  late final TextEditingController _key;
  late final TextEditingController _extSpeech;
  late final TextEditingController _extSummary;
  String? _status;
  bool _testing = false;
  bool _healthLoaded = false;
  bool _healthOk = false;
  List<String> _localLlms = const [];
  List<Map<String, dynamic>> _catalog = const [];
  Timer? _poll;
  String? _downloading;
  int _received = 0;
  int _total = 0;
  int _modelsSeen = 0;

  // On-device models: the store (for progress and deletion) and the one
  // download that may be running.
  DeviceModels? _deviceStore;
  String? _deviceDownload;
  Timer? _deviceTimer;

  @override
  void initState() {
    super.initState();
    _extUrl = TextEditingController(text: s.externalUrl);
    _key = TextEditingController(text: s.externalKey);
    _extSpeech = TextEditingController(text: s.externalSpeech);
    _extSummary = TextEditingController(text: s.externalSummary);
    _modelsSeen = widget.takes.modelsRevision;
    widget.takes.addListener(_onTakesChanged);
    _refreshHealth();
  }

  /// A model deleted under "Models on this machine" must leave this picker too.
  void _onTakesChanged() {
    if (widget.takes.modelsRevision == _modelsSeen) return;
    _modelsSeen = widget.takes.modelsRevision;
    _refreshHealth();
  }

  Future<void> _refreshHealth() async {
    var h = await widget.takes.ai.health();
    if (!mounted) return;
    if (h == null) {
      // The first call can race the service/USB bridge as the panel opens.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      h = await widget.takes.ai.health();
      if (!mounted) return;
    }
    // Resolving the device health is also what opens the model store, so the
    // pickers below can read installed state synchronously.
    await widget.takes.ai.deviceHealth();
    final store = widget.takes.ai.device.modelsIfReady;
    if (!mounted) return;
    setState(() {
      _healthLoaded = true;
      _healthOk = h != null;
      _deviceStore = store;
      _applyHealth(h);
    });
  }

  void _applyHealth(Map<String, dynamic>? h) {
    _localLlms = [for (final m in (h?['local_llms'] as List? ?? const [])) m.toString()];
    _catalog = [
      for (final m in (h?['summary_catalog'] as List? ?? const []))
        if (m is Map) m.cast<String, dynamic>(),
    ];
  }

  @override
  void dispose() {
    widget.takes.removeListener(_onTakesChanged);
    _poll?.cancel();
    _deviceTimer?.cancel();
    for (final c in [_extUrl, _key, _extSpeech, _extSummary]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    s.externalUrl = _extUrl.text.trim().isEmpty ? s.externalUrl : _extUrl.text.trim();
    s.externalKey = _key.text.trim();
    s.externalSpeech = _extSpeech.text.trim().isEmpty ? s.externalSpeech : _extSpeech.text.trim();
    s.externalSummary = _extSummary.text.trim().isEmpty ? s.externalSummary : _extSummary.text.trim();
    await s.save();
    if (mounted) setState(() {});
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _status = null;
    });
    await _save();
    final problem = await widget.takes.probeAi();
    final h = await widget.takes.ai.health();
    await widget.takes.ai.deviceHealth();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _healthLoaded = true;
      _healthOk = h != null;
      _deviceStore = widget.takes.ai.device.modelsIfReady;
      _applyHealth(h);
      _status = problem ?? 'Ready — ${s.speechLabel}; ${s.summaryLabel}';
    });
  }

  // --- on-device models -----------------------------------------------------

  Future<void> _downloadDevice(DeviceModel model) async {
    final store = await widget.takes.ai.ensureDeviceModels();
    if (!mounted) return;
    setState(() {
      _deviceStore = store;
      _deviceDownload = model.id;
      _status = null;
    });
    unawaited(store.download(model));
    _deviceTimer?.cancel();
    _deviceTimer = Timer.periodic(const Duration(milliseconds: 300), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final progress = store.progressOf(model);
      setState(() {});
      if (progress == null || !progress.finished) return;
      timer.cancel();
      if (progress.state == 'done') {
        // A model you just downloaded is the one you meant to use.
        if (model.kind == ModelKind.speech) {
          s.setDeviceSpeech(model.label);
        } else {
          s.setDeviceSummary(model.id);
        }
      }
      await _refreshHealth();
      if (!mounted) return;
      setState(() {
        _deviceDownload = null;
        _status = progress.state == 'done'
            ? '${model.label} is on this device.'
            : progress.state == 'error'
                ? 'Download failed: ${progress.error ?? 'unknown error'}'
                : 'Download cancelled.';
      });
    });
  }

  void _cancelDeviceDownload(DeviceModel model) {
    _deviceStore?.cancel(model);
  }

  Future<void> _deleteDevice(DeviceModel model) async {
    final store = await widget.takes.ai.ensureDeviceModels();
    final freed = await store.delete(model);
    if (model.kind == ModelKind.speech && s.deviceSpeech == model.label) {
      final left = store.installed(ModelKind.speech);
      if (left.isNotEmpty) s.setDeviceSpeech(left.first.label);
    }
    if (model.kind == ModelKind.summary && s.deviceSummary == model.id) {
      s.setDeviceSummary('auto');
    }
    await _refreshHealth();
    if (!mounted) return;
    setState(() => _status =
        '${DeviceModel.sizeLabel(freed)} freed on this device.');
  }

  // --- catalog downloads ----------------------------------------------------

  Future<void> _download(String name) async {
    final ai = widget.takes.ai;
    setState(() {
      _downloading = name;
      _received = 0;
      _total = 0;
      _status = null;
    });
    final started = await ai.startModelDownload(name);
    if (!mounted) return;
    if (started == null) {
      setState(() {
        _downloading = null;
        _status = 'Could not start the download — is the local service running?';
      });
      return;
    }
    if (started['state'] == 'done') {
      await _finishDownload(name);
      return;
    }
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (timer) async {
      final state = await ai.modelDownload(name);
      if (!mounted) {
        timer.cancel();
        return;
      }
      final status = state?['state']?.toString();
      setState(() {
        _received = (state?['received'] as num?)?.toInt() ?? _received;
        _total = (state?['total'] as num?)?.toInt() ?? _total;
        if (status == 'error') {
          _status = 'Download failed: ${state?['error'] ?? 'unknown error'}';
        }
      });
      if (status == 'done' || status == 'error' || status == null) {
        timer.cancel();
        if (status == 'done') {
          await _finishDownload(name);
        } else if (mounted) {
          setState(() => _downloading = null);
        }
      }
    });
  }

  Future<void> _finishDownload(String name) async {
    await _refreshHealth();
    s.setLocalSummary(name);
    if (!mounted) return;
    setState(() {
      _downloading = null;
      _status = '${AiSettings.shortModelName(name)} is ready.';
    });
  }

  String get _downloadLabel {
    final name = _downloading;
    if (name == null) return '';
    final short = AiSettings.shortModelName(name);
    if (_total > 0) {
      return 'Downloading $short — ${(_received * 100 / _total).round()}%';
    }
    return 'Downloading $short — ${(_received / 1000000).toStringAsFixed(1)} MB';
  }

  // --- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final primary = s.speechLanguages.isEmpty
        ? ''
        : SpeechLanguages.nameOf(s.speechLanguages.first) ?? s.speechLanguages.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Route(
          title: 'Speech',
          detail: 'Turns the recording into text.',
          backend: s.speechBackend,
          onDevice: () {
            s.setSpeechBackend(AiBackend.device);
            setState(() => _status = null);
            widget.takes.ai.ensureDeviceModels().then((_) => _refreshHealth());
          },
          onLocal: () {
            s.setSpeechBackend(AiBackend.local);
            setState(() => _status = null);
            _refreshHealth();
          },
          onExternal: () {
            s.setSpeechBackend(AiBackend.external);
            setState(() => _status = null);
          },
        ),
        const SizedBox(height: Tokens.s2),
        if (s.speechOnDevice)
          ..._deviceSpeech()
        else if (!s.speechExternal)
          ..._localSpeech()
        else
          ..._externalSpeech(),
        const SizedBox(height: Tokens.s3),
        Text('Languages in the recording', style: Tokens.body),
        const SizedBox(height: Tokens.s1),
        LanguagePicker(
          selected: s.speechLanguages,
          onChanged: (v) => setState(() {
            s.setSpeechLanguages(v);
            _status = null;
          }),
        ),
        const SizedBox(height: Tokens.s1),
        Text(
          s.speechLanguages.isEmpty
              ? 'Auto: whisper detects the language. Narrow it when takes are short or mix '
                  'languages — a known language is one whisper does not have to guess.'
              : 'Asked before a take is transcribed, and remembered across sessions. With more '
                  'than one, whisper detects and $primary is only forced when the guess lands '
                  'outside the list.',
          style: Tokens.caption,
        ),
        const SizedBox(height: Tokens.s4),
        const Divider(height: 1),
        const SizedBox(height: Tokens.s4),
        _Route(
          title: 'Summary',
          detail: 'Writes the notes and the take title.',
          backend: s.summaryBackend,
          onDevice: () {
            s.setSummaryBackend(AiBackend.device);
            setState(() => _status = null);
            widget.takes.ai.ensureDeviceModels().then((_) => _refreshHealth());
          },
          onLocal: () {
            s.setSummaryBackend(AiBackend.local);
            setState(() => _status = null);
            _refreshHealth();
          },
          onExternal: () {
            s.setSummaryBackend(AiBackend.external);
            setState(() => _status = null);
          },
        ),
        const SizedBox(height: Tokens.s2),
        if (s.summaryOnDevice)
          ..._deviceSummary()
        else if (!s.summaryExternal)
          ..._localSummary()
        else
          ..._externalSummary(),
        const SizedBox(height: Tokens.s4),
        Row(
          children: [
            OutlinedButton(
              onPressed: _testing || _downloading != null ? null : _test,
              child: _testing
                  ? const SizedBox(
                      width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Test connection'),
            ),
            const SizedBox(width: Tokens.s3),
            Expanded(
              child: Text(
                _status ?? '${s.speechLabel}  ·  ${s.summaryLabel}',
                style: Tokens.caption.copyWith(
                  color: _status == null ? Tokens.inkSoft : Tokens.ink,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // --- on this device --------------------------------------------------------

  List<Widget> _deviceSpeech() => [
        const SizedBox(height: Tokens.s1),
        Text('On this device, with whisper', style: Tokens.body),
        const SizedBox(height: Tokens.s1),
        Wrap(
          spacing: Tokens.s2,
          runSpacing: Tokens.s2,
          children: [
            for (final m in deviceSpeechModels)
              _deviceChip(
                m,
                selected: s.deviceSpeech == m.label,
                onSelect: () => setState(() {
                  s.setDeviceSpeech(m.label);
                  _status = null;
                }),
              ),
          ],
        ),
        ..._deviceProgress(ModelKind.speech),
        const SizedBox(height: Tokens.s1),
        Text(
          'Runs on this phone: no service, no network, nothing uploaded. A take is decoded by '
          'the platform’s own codecs, so it works with the screen off and on a train. Slower '
          'than a PC — the machine option is still there for long recordings.',
          style: Tokens.caption,
        ),
        ..._installedRows(ModelKind.speech),
      ];

  List<Widget> _deviceSummary() => [
        const SizedBox(height: Tokens.s1),
        Text('On this device, with llama.cpp', style: Tokens.body),
        const SizedBox(height: Tokens.s1),
        Wrap(
          spacing: Tokens.s2,
          runSpacing: Tokens.s2,
          children: [
            for (final m in deviceSummaryModels)
              _deviceChip(
                m,
                selected: s.deviceSummary == m.id,
                onSelect: () => setState(() {
                  s.setDeviceSummary(m.id);
                  _status = null;
                }),
              ),
            ChoiceChipButton(
              label: 'extractive',
              selected: s.deviceSummary == 'extractive',
              onTap: () => setState(() {
                s.setDeviceSummary('extractive');
                _status = null;
              }),
            ),
          ],
        ),
        ..._deviceProgress(ModelKind.summary),
        const SizedBox(height: Tokens.s1),
        Text(
          s.deviceSummary == 'extractive'
              ? 'No model: real sentences from the transcript, ranked into the template. '
                  'Nothing invented, works offline, instant — but it cannot rewrite or merge.'
              : 'A GGUF stays in this app and writes the notes on the phone. Bigger writes tighter '
                  'sections and misses fewer actions, and is slower; the machine can carry 3B and 7B.',
          style: Tokens.caption,
        ),
        ..._installedRows(ModelKind.summary),
      ];

  Widget _deviceChip(DeviceModel model,
      {required bool selected, required VoidCallback onSelect}) {
    final store = _deviceStore;
    final installed = store?.isInstalled(model) ?? false;
    final progress = store?.progressOf(model);
    final busy = _deviceDownload == model.id && (progress == null || !progress.finished);

    if (busy) {
      final percent = progress?.fraction;
      return ChoiceChipButton(
        label: '${model.label} · ${percent == null ? 'starting…' : '${(percent * 100).round()}%'}',
        compact: true,
        selected: false,
        onTap: () => _cancelDeviceDownload(model),
      );
    }
    if (installed) {
      return ChoiceChipButton(
        label: model.label,
        compact: true,
        selected: selected,
        onTap: onSelect,
      );
    }
    return ChoiceChipButton(
      label: '${model.label} · ${DeviceModel.sizeLabel(model.bytes)}',
      compact: true,
      selected: false,
      icon: Icons.download,
      onTap: _deviceDownload == null ? () => _downloadDevice(model) : null,
    );
  }

  List<Widget> _deviceProgress(ModelKind kind) {
    final store = _deviceStore;
    final active = _deviceDownload;
    if (store == null || active == null) return const [];
    final model = DeviceModels.byId(active);
    if (model == null || model.kind != kind) return const [];
    final progress = store.progressOf(model);
    if (progress == null || progress.finished) return const [];
    return [
      const SizedBox(height: Tokens.s1),
      ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: progress.fraction,
          minHeight: 3,
          backgroundColor: Tokens.rule,
          color: Tokens.accent,
        ),
      ),
      const SizedBox(height: Tokens.s1),
      Text('Downloading ${model.label} — ${progress.label}', style: Tokens.caption),
    ];
  }

  /// One row per installed model, with what it takes and one tap to free it.
  List<Widget> _installedRows(ModelKind kind) {
    final store = _deviceStore;
    if (store == null) return const [];
    final models = store.installed(kind);
    if (models.isEmpty) {
      return kind == ModelKind.summary
          ? const []
          : [
              const SizedBox(height: Tokens.s1),
              Text('No whisper model on this device yet.', style: Tokens.caption),
            ];
    }
    return [
      const SizedBox(height: Tokens.s1),
      for (final m in models)
        Row(
          children: [
            Expanded(
              child: Text(
                '${kind == ModelKind.speech ? 'whisper ${m.label}' : m.label} · '
                '${DeviceModel.sizeLabel(store.installedBytes(m))} on this device',
                style: Tokens.caption,
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              tooltip: 'Delete ${m.label}',
              onPressed: _deviceDownload == null ? () => _deleteDevice(m) : null,
              icon: const Icon(Icons.delete_outline, color: Tokens.inkSoft),
            ),
          ],
        ),
      Text(
        '${DeviceModel.sizeLabel(store.totalBytes)} used by on-device models.',
        style: Tokens.caption,
      ),
    ];
  }

  List<Widget> _localSpeech() => [
        const SizedBox(height: Tokens.s1),
        Text('On this machine, with whisper', style: Tokens.body),
        const SizedBox(height: Tokens.s1),
        Wrap(
          spacing: Tokens.s2,
          runSpacing: Tokens.s2,
          children: [
            for (final m in AiSettings.whisperModels)
              ChoiceChipButton(
                label: m,
                selected: s.localSpeech == m,
                onTap: () {
                  s.setLocalSpeech(m);
                  setState(() => _status = null);
                },
              ),
          ],
        ),
        const SizedBox(height: Tokens.s1),
        Text(
          'Larger sizes handle accents and code-switching better and take longer. '
          'Service at ${s.localUrl} — found automatically, no address to type.',
          style: Tokens.caption,
        ),
      ];

  List<Widget> _localSummary() {
    final catalogNames = {for (final c in _catalog) c['name'].toString()};
    final installed = <String>{
      for (final c in _catalog)
        if (c['downloaded'] == true) c['name'].toString(),
      ..._localLlms,
    };
    final extras = [for (final m in _localLlms) if (!catalogNames.contains(m)) m];
    final canDownload = _catalog.any((c) => c['downloaded'] != true);

    return [
      const SizedBox(height: Tokens.s1),
      Text('On this machine, with llama.cpp', style: Tokens.body),
      const SizedBox(height: Tokens.s1),
      Wrap(
        spacing: Tokens.s2,
        runSpacing: Tokens.s2,
        children: [
          ChoiceChipButton(
            label: 'default',
            selected: s.localSummary == 'auto',
            onTap: () => setState(() {
              s.setLocalSummary('auto');
              _status = null;
            }),
          ),
          for (final c in _catalog) _catalogChip(c),
          for (final m in extras)
            ChoiceChipButton(
              label: _shortName(m),
              selected: s.localSummary == m,
              onTap: () => setState(() {
                s.setLocalSummary(m);
                _status = null;
              }),
            ),
          ChoiceChipButton(
            label: 'extractive',
            selected: s.localSummary == 'extractive',
            onTap: () => setState(() {
              s.setLocalSummary('extractive');
              _status = null;
            }),
          ),
        ],
      ),
      const SizedBox(height: Tokens.s1),
      if (_downloading != null) ...[
        const SizedBox(height: Tokens.s1),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: _total > 0 ? _received / _total : null,
            minHeight: 3,
            backgroundColor: Tokens.rule,
            color: Tokens.accent,
          ),
        ),
        const SizedBox(height: Tokens.s1),
        Text(_downloadLabel, style: Tokens.caption),
      ] else if (!_healthLoaded)
        Text('Checking the local service…', style: Tokens.caption)
      else if (!_healthOk)
        Text(
          'Local service not reachable — start scripts/ai_server.py, then press Test '
          'connection. Until it answers, summaries fall back to extractive.',
          style: Tokens.caption,
        )
      else
        Text(
          installed.isEmpty
              ? 'No GGUF yet. Tap a model above to download it on the machine running the '
                  'service (or run scripts/fetch_model.py), then press Test connection.'
              : canDownload
                  ? 'Tap a sized model to download it on the serving machine. More parameters '
                      'write tighter notes but answer slower: 1.5B is quick, 3B is the CPU sweet '
                      'spot, 7B is best when you can wait. Only the summary uses it; transcription '
                      'accuracy comes from the whisper size above.'
                  : 'More parameters write tighter notes but answer slower: 1.5B is quick, 3B is '
                      'the CPU sweet spot, 7B is best when you can wait. Only the summary uses '
                      'it; transcription accuracy comes from the whisper size above.',
          style: Tokens.caption,
        ),
    ];
  }

  Widget _catalogChip(Map<String, dynamic> entry) {
    final name = entry['name'].toString();
    final downloaded = entry['downloaded'] == true;
    final size = entry['size_gb'];
    final label = downloaded
        ? _shortName(name)
        : '${AiSettings.shortModelName(name)}${size is num ? ' · $size GB' : ''}';
    if (downloaded) {
      return ChoiceChipButton(
        label: label,
        selected: s.localSummary == name,
        onTap: () => setState(() {
          s.setLocalSummary(name);
          _status = null;
        }),
      );
    }
    return ChoiceChipButton(
      label: label,
      selected: false,
      icon: Icons.download,
      onTap: _downloading == null ? () => _download(name) : null,
    );
  }

  List<Widget> _externalSpeech() => [
        const SizedBox(height: Tokens.s2),
        _Field(
          label: 'Speech model',
          controller: _extSpeech,
          hint: 'whisper-1',
          onSubmitted: (_) => _save(),
        ),
        ..._endpoints(),
      ];

  List<Widget> _externalSummary() => [
        const SizedBox(height: Tokens.s2),
        _Field(
          label: 'Summary model',
          controller: _extSummary,
          hint: 'gpt-4o-mini',
          onSubmitted: (_) => _save(),
        ),
        if (s.speechExternal) ...[
          const SizedBox(height: Tokens.s2),
          Text(
            'Uses the external service configured under Speech (base URL and API key).',
            style: Tokens.caption,
          ),
        ] else
          ..._endpoints(),
      ];

  /// The shared OpenAI-compatible endpoint. Shown once, under the first half
  /// that is set to External, so it is never buried below an unrelated section.
  List<Widget> _endpoints() => [
        const SizedBox(height: Tokens.s3),
        Text('External service', style: Tokens.section),
        const SizedBox(height: Tokens.s2),
        _Field(
          label: 'Base URL',
          controller: _extUrl,
          hint: 'https://api.openai.com/v1',
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: Tokens.s2),
        _Field(
          label: 'API key',
          controller: _key,
          hint: 'sk-…',
          obscure: true,
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: Tokens.s2),
        Text(
          'Used by any half set to External. Audio and transcripts go to that service and are '
          'billed by it. The key is kept in this app’s preferences, not a system keystore.',
          style: Tokens.caption.copyWith(color: Tokens.warn),
        ),
      ];

  static String _shortName(String gguf) {
    final n = AiSettings.shortModelName(gguf);
    return n.length > 22 ? '${n.substring(0, 22)}…' : n;
  }
}

/// One routing decision: speech or summary, on this device / this machine /
/// external.
class _Route extends StatelessWidget {
  const _Route({
    required this.title,
    required this.detail,
    required this.backend,
    required this.onDevice,
    required this.onLocal,
    required this.onExternal,
  });

  final String title;
  final String detail;
  final AiBackend backend;
  final VoidCallback onDevice;
  final VoidCallback onLocal;
  final VoidCallback onExternal;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Tokens.section),
        Text(detail, style: Tokens.caption),
        const SizedBox(height: Tokens.s2),
        Wrap(
          spacing: Tokens.s2,
          runSpacing: Tokens.s2,
          children: [
            ChoiceChipButton(
              label: 'On this device',
              compact: true,
              selected: backend == AiBackend.device,
              onTap: onDevice,
            ),
            ChoiceChipButton(
              label: 'On this machine',
              compact: true,
              selected: backend == AiBackend.local,
              onTap: onLocal,
            ),
            ChoiceChipButton(
              label: 'External service',
              compact: true,
              selected: backend == AiBackend.external,
              onTap: onExternal,
            ),
          ],
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.hint,
    this.obscure = false,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Tokens.caption),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          onSubmitted: onSubmitted,
          style: Tokens.data,
          decoration: InputDecoration(hintText: hint),
        ),
      ],
    );
  }
}
