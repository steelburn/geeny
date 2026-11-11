import 'package:flutter/material.dart';

import '../ai/ai_settings.dart';
import '../state/takes.dart';
import '../theme/tokens.dart';

/// Housekeeping for the machine running the AI service: every downloaded model,
/// what it takes, and one tap to free it.
///
/// Two kinds are listed because two kinds exist: summary GGUFs in
/// `~/.cache/notra/models/` and the whisper weights faster-whisper keeps in the
/// Hugging Face cache. Both are per-size downloads, so a machine that has tried
/// four whisper sizes is carrying hundreds of megabytes it may not need.
class ModelHousekeeping extends StatefulWidget {
  const ModelHousekeeping({super.key, required this.takes});
  final Takes takes;

  @override
  State<ModelHousekeeping> createState() => _ModelHousekeepingState();
}

class _ModelHousekeepingState extends State<ModelHousekeeping> {
  List<Map<String, dynamic>> _models = const [];
  int _total = 0;
  bool _loading = true;
  String? _error;
  String? _status;
  String? _deleting;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final storage = await widget.takes.ai.modelStorage();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (storage == null) {
        _error = 'The local AI service is not reachable, so its models cannot be listed. '
            'Start scripts/ai_server.py, then refresh.';
        return;
      }
      _error = null;
      _models = [
        for (final m in (storage['models'] as List? ?? const []))
          if (m is Map) m.cast<String, dynamic>(),
      ];
      _total = (storage['total_bytes'] as num?)?.toInt() ?? 0;
    });
  }

  Future<void> _delete(Map<String, dynamic> model) async {
    final kind = (model['kind'] ?? 'summary').toString();
    final name = (model['name'] ?? '').toString();
    final label = kind == 'speech' ? 'whisper $name' : AiSettings.shortModelName(name);
    final selected = kind == 'summary' && widget.takes.aiSettings.localSummary == name;
    final consequence = switch (kind) {
      'speech' => 'The next transcription with this size downloads it again.',
      'partial' => 'An interrupted download cannot resume, so nothing is lost.',
      _ => selected
          ? 'This is the selected summary model, so the app falls back to the service '
              'default until you pick another.'
          : 'Summary models you have not selected are not in use right now.',
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Tokens.surface,
        title: Text('Delete $label?', style: Tokens.title),
        content: Text(
          '${_size((model['bytes'] as num?)?.toInt() ?? 0)} is freed on the machine running '
          'the AI service. The model can be downloaded again from this panel.\n\n'
          '$consequence',
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
    if (ok != true || !mounted) return;

    setState(() {
      _deleting = '$kind:$name';
      _status = null;
    });
    final result = await widget.takes.deleteModel(kind, name);
    if (!mounted) return;
    setState(() {
      _deleting = null;
      _status = result.error ?? 'Deleted $label — ${_size(result.freed)} freed.';
    });
    await _load();
  }

  static String _size(int bytes) {
    if (bytes <= 0) return '0 B';
    final gb = bytes / 1e9;
    if (gb >= 1) return '${gb.toStringAsFixed(2)} GB';
    final mb = bytes / 1e6;
    if (mb >= 1) return '${mb.toStringAsFixed(0)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} kB';
  }

  @override
  Widget build(BuildContext context) {
    final summary = _models.where((m) => m['kind'] == 'summary').toList();
    final speech = _models.where((m) => m['kind'] == 'speech').toList();
    final partials = _models.where((m) => m['kind'] == 'partial').toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _loading
                    ? 'Checking the machine that runs the AI service…'
                    : _models.isEmpty
                        ? 'Nothing downloaded yet — speech and summary models appear here once used.'
                        : '${_models.length} ${_models.length == 1 ? 'model' : 'models'} · '
                            '${_size(_total)} on the serving machine',
                style: Tokens.bodySmall,
              ),
            ),
            const SizedBox(width: Tokens.s2),
            TextButton.icon(
              onPressed: _loading || _deleting != null ? null : _load,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Refresh'),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: Tokens.s2),
          Text(_error!, style: Tokens.bodySmall.copyWith(color: Tokens.danger)),
        ],
        if (summary.isNotEmpty) ...[
          const SizedBox(height: Tokens.s3),
          Text('Summary models', style: Tokens.section),
          const SizedBox(height: Tokens.s1),
          const Divider(height: 1),
          for (final model in summary) _row(model),
        ],
        if (partials.isNotEmpty) ...[
          const SizedBox(height: Tokens.s3),
          Text('Unfinished downloads', style: Tokens.section),
          const SizedBox(height: Tokens.s1),
          const Divider(height: 1),
          for (final model in partials) _row(model),
        ],
        if (speech.isNotEmpty) ...[
          const SizedBox(height: Tokens.s3),
          Text('Speech models (whisper)', style: Tokens.section),
          const SizedBox(height: Tokens.s1),
          const Divider(height: 1),
          for (final model in speech)
            _row(model, label: 'whisper ${model['name']}'),
        ],
        if (_status != null) ...[
          const SizedBox(height: Tokens.s2),
          Text(_status!, style: Tokens.caption.copyWith(color: Tokens.ink)),
        ],
        const SizedBox(height: Tokens.s2),
        Text(
          'Larger models take more space and time. Deleting one frees the space immediately; '
          'it downloads again if you select it later. Summary models and whisper sizes are '
          'independent, so keeping one of each is all a single setup needs.',
          style: Tokens.caption,
        ),
      ],
    );
  }

  Widget _row(Map<String, dynamic> model, {String? label}) {
    final kind = (model['kind'] ?? 'summary').toString();
    final name = (model['name'] ?? '').toString();
    final bytes = (model['bytes'] as num?)?.toInt() ?? 0;
    final busy = _deleting == '$kind:$name';
    final text = label ??
        (kind == 'partial'
            ? name
            : AiSettings.shortModelName(name));
    return SizedBox(
      height: Tokens.targetCompact + 4,
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Tokens.body.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(width: Tokens.s2),
          Text(_size(bytes), style: Tokens.dataSmall),
          const SizedBox(width: Tokens.s1),
          IconButton(
            onPressed: _deleting != null ? null : () => _delete(model),
            tooltip: 'Delete $text',
            iconSize: 18,
            color: Tokens.danger,
            disabledColor: Tokens.inkSoft.withValues(alpha: 0.4),
            constraints: const BoxConstraints(
              minWidth: Tokens.targetCompact,
              minHeight: Tokens.targetCompact,
            ),
            icon: busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Tokens.inkSoft),
                  )
                : const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}
