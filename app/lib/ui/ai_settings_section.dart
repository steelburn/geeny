import 'package:flutter/material.dart';

import '../ai/ai_settings.dart';
import '../state/takes.dart';
import '../theme/tokens.dart';
import 'choice_chip.dart';

/// Transcription settings. Speech and summary are routed **independently**, so
/// local whisper + an external chat model (or the other way round) is a normal
/// setup. The local service address is not edited here: the app knows it.
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
  List<String> _localLlms = const [];

  @override
  void initState() {
    super.initState();
    _extUrl = TextEditingController(text: s.externalUrl);
    _key = TextEditingController(text: s.externalKey);
    _extSpeech = TextEditingController(text: s.externalSpeech);
    _extSummary = TextEditingController(text: s.externalSummary);
    _refreshHealth();
  }

  Future<void> _refreshHealth() async {
    final h = await widget.takes.ai.health();
    if (!mounted) return;
    setState(() {
      _localLlms = [for (final m in (h?['local_llms'] as List? ?? const [])) m.toString()];
    });
  }

  @override
  void dispose() {
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
    if (!mounted) return;
    setState(() {
      _testing = false;
      _localLlms = [for (final m in (h?['local_llms'] as List? ?? const [])) m.toString()];
      _status = problem ?? 'Reachable — ${s.speechLabel}; ${s.summaryLabel}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Route(
          title: 'Speech',
          detail: 'Turns the recording into text.',
          local: !s.speechExternal,
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
        if (!s.speechExternal) ..._localSpeech() else ..._externalSpeech(),
        const SizedBox(height: Tokens.s4),
        const Divider(height: 1),
        const SizedBox(height: Tokens.s4),
        _Route(
          title: 'Summary',
          detail: 'Writes the notes and the take title.',
          local: !s.summaryExternal,
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
        if (!s.summaryExternal) ..._localSummary() else ..._externalSummary(),
        if (s.usesExternal) ...[
          const SizedBox(height: Tokens.s4),
          const Divider(height: 1),
          const SizedBox(height: Tokens.s4),
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
            'Used by whichever half is set to External. Audio and transcripts go to that '
            'service and are billed by it. The key is kept in this app’s preferences, not a '
            'system keystore.',
            style: Tokens.caption.copyWith(color: Tokens.warn),
          ),
        ],
        const SizedBox(height: Tokens.s4),
        Row(
          children: [
            OutlinedButton(
              onPressed: _testing ? null : _test,
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

  List<Widget> _localSummary() => [
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
            for (final m in _localLlms)
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
        Text(
          _localLlms.isEmpty
              ? 'No GGUF yet — run scripts/fetch_model.py (or drop a .gguf in '
                  '~/.cache/notra/models/) and press Test connection. Without one, summaries '
                  'are extractive.'
              : 'More parameters write tighter notes but answer slower: 1.5B is quick, 3B is '
                  'the CPU sweet spot, 7B is best when you can wait. Only the summary uses it; '
                  'transcription accuracy comes from the whisper size above.',
          style: Tokens.caption,
        ),
      ];

  List<Widget> _externalSpeech() => [
        const SizedBox(height: Tokens.s2),
        _Field(
          label: 'Speech model',
          controller: _extSpeech,
          hint: 'whisper-1',
          onSubmitted: (_) => _save(),
        ),
      ];

  List<Widget> _externalSummary() => [
        const SizedBox(height: Tokens.s2),
        _Field(
          label: 'Summary model',
          controller: _extSummary,
          hint: 'gpt-4o-mini',
          onSubmitted: (_) => _save(),
        ),
      ];

  static String _shortName(String gguf) {
    final n = AiSettings.shortModelName(gguf);
    return n.length > 22 ? '${n.substring(0, 22)}…' : n;
  }
}

/// One routing decision: speech or summary, local or external.
class _Route extends StatelessWidget {
  const _Route({
    required this.title,
    required this.detail,
    required this.local,
    required this.onLocal,
    required this.onExternal,
  });

  final String title;
  final String detail;
  final bool local;
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
              label: 'On this machine',
              compact: true,
              selected: local,
              onTap: onLocal,
            ),
            ChoiceChipButton(
              label: 'External service',
              compact: true,
              selected: !local,
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
