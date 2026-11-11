import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/ask.dart';
import '../state/takes.dart';
import '../theme/tokens.dart';
import 'choice_chip.dart';
import 'notes_sheet.dart';
import 'widgets.dart';

/// Search across every transcribed take, or ask a question and get an answer
/// with citations back to the take and timestamp.
///
/// Both run on the device: the index is built from the notes the app already has,
/// retrieval is local BM25, and only an answer's prose is written by a model — the
/// chosen summary backend, or no model at all (the passages themselves).
Future<void> openAsk(BuildContext context, Takes takes) async {
  final hit = await showModalBottomSheet<AskHit>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Tokens.surface,
    elevation: 0,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Tokens.r2)),
    ),
    builder: (_) => SheetSurface(child: _AskSheet(takes: takes)),
  );
  if (hit == null || !context.mounted) return;

  final take = takes.takeForId(hit.id);
  if (take == null) return;
  if (hit.start != null && take.hasAudio) {
    await takes.cue(take, Duration(milliseconds: (hit.start! * 1000).round()));
  }
  if (!context.mounted) return;
  await openNotes(context, takes, take, showTranscript: true);
}

enum _Mode { search, ask }

class _AskSheet extends StatefulWidget {
  const _AskSheet({required this.takes});
  final Takes takes;

  @override
  State<_AskSheet> createState() => _AskSheetState();
}

class _AskSheetState extends State<_AskSheet> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  _Mode _mode = _Mode.search;
  List<AskHit> _hits = const [];
  AskAnswer? _answer;
  bool _busy = false;
  bool _searched = false;
  String? _error;
  String? _noMatch;

  Takes get takes => widget.takes;

  @override
  void initState() {
    super.initState();
    // The index is built from notes the app already has; rebuild it on open so a
    // take transcribed since the last visit is searchable.
    takes.syncSearchIndex().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      setState(() {
        _hits = const [];
        _searched = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final hits = await takes.searchNotes(q);
    if (!mounted) return;
    setState(() {
      _hits = hits;
      _searched = true;
      _busy = false;
      _error = takes.searchError;
    });
  }

  Future<void> _ask(String question) async {
    final q = question.trim();
    if (q.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _answer = null;
      _noMatch = null;
    });
    final answer = await takes.askNotes(q);
    if (!mounted) return;
    setState(() {
      _answer = answer;
      _busy = false;
      _error = takes.searchError;
      _noMatch = answer == null && takes.searchError == null
          ? 'Nothing in your notes mentions “$q” yet.'
          : null;
    });
  }

  void _onChanged(String value) {
    setState(() {}); // the clear affordance follows the field
    if (_mode == _Mode.ask) {
      setState(() {
        _error = null;
        _noMatch = null;
      });
      if (_answer != null) setState(() => _answer = null);
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 280), () => _search(value));
  }

  void _switch(_Mode mode) {
    if (_mode == mode) return;
    setState(() {
      _mode = mode;
      _hits = const [];
      _answer = null;
      _searched = false;
      _error = null;
      _noMatch = null;
    });
    if (_mode == _Mode.search && _controller.text.trim().isNotEmpty) {
      _search(_controller.text);
    }
  }

  void _useExample(String text) {
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
    if (_mode == _Mode.ask) {
      _ask(text);
    } else {
      _search(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Tokens.s5, Tokens.s4, Tokens.s5, Tokens.s3),
        child: SizedBox(
          height: height * 0.84,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              const SizedBox(height: Tokens.s3),
              _modeRow(),
              const SizedBox(height: Tokens.s3),
              _field(),
              const SizedBox(height: Tokens.s2),
              _statusLine(),
              const SizedBox(height: Tokens.s2),
              const Divider(height: 1),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final count = takes.indexedTakes;
    final passages = takes.indexedPassages;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Ask your takes', style: Tokens.title),
              const SizedBox(height: Tokens.s1),
              Text(
                count == 0
                    ? 'Search reads transcripts and summaries — transcribe a take first.'
                    : '$count ${count == 1 ? 'take' : 'takes'} · $passages '
                        '${passages == 1 ? 'passage' : 'passages'} · searched on this device',
                style: Tokens.caption,
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: () => Navigator.of(context).pop(),
          constraints: const BoxConstraints(minWidth: Tokens.target, minHeight: Tokens.target),
          icon: const Icon(Icons.close, size: 20, color: Tokens.inkSoft),
          tooltip: 'Close',
        ),
      ],
    );
  }

  Widget _modeRow() {
    return Row(
      children: [
        ChoiceChipButton(
          label: 'Search',
          compact: true,
          selected: _mode == _Mode.search,
          onTap: () => _switch(_Mode.search),
        ),
        const SizedBox(width: Tokens.s2),
        ChoiceChipButton(
          label: 'Ask',
          compact: true,
          selected: _mode == _Mode.ask,
          onTap: () => _switch(_Mode.ask),
        ),
      ],
    );
  }

  Widget _field() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            autofocus: true,
            style: Tokens.body,
            textInputAction: TextInputAction.search,
            onChanged: _onChanged,
            onSubmitted: (v) => _mode == _Mode.ask ? _ask(v) : _search(v),
            decoration: InputDecoration(
              hintText: _mode == _Mode.ask
                  ? 'What did we decide about the sampling plan?'
                  : 'Words, a name, a project…',
              prefixIcon: Icon(
                _mode == _Mode.ask ? Icons.chat_bubble_outline : Icons.search,
                size: 18,
                color: Tokens.inkSoft,
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: Tokens.target),
              suffixIcon: _controller.text.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () {
                        _controller.clear();
                        _onChanged('');
                        if (_mode == _Mode.ask) {
                          setState(() {
                            _answer = null;
                            _error = null;
                          });
                        }
                      },
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close, size: 16, color: Tokens.inkSoft),
                    ),
            ),
          ),
        ),
        if (_mode == _Mode.ask) ...[
          const SizedBox(width: Tokens.s2),
          FilledButton(
            onPressed: _busy || _controller.text.trim().isEmpty
                ? null
                : () => _ask(_controller.text),
            child: _busy ? const _WorkingLabel('Asking') : const Text('Ask'),
          ),
        ],
      ],
    );
  }

  Widget _statusLine() {
    final error = _error ?? takes.searchError;
    if (_busy) {
      return Text(
        _mode == _Mode.ask ? 'Reading the matching passages…' : 'Searching…',
        style: Tokens.caption,
      );
    }
    if (error != null) {
      return Text(error, style: Tokens.caption.copyWith(color: Tokens.danger));
    }
    if (_mode == _Mode.ask && _answer != null) {
      return Text(
        _answer!.extractive
            ? 'No model wrote this, so these are the matching passages themselves.'
            : 'Answered by ${_answer!.engine}',
        style: Tokens.caption,
      );
    }
    return const SizedBox(height: Tokens.s4);
  }

  Widget _body() {
    if (takes.indexedTakes == 0 && !_busy) {
      return _empty(
        'Nothing to search yet',
        'Search and ask run on the text of your takes — transcription first, then the '
            'transcript and its summary are searchable. Tap a take, choose '
            '“Transcribe & summarise”, and come back.',
      );
    }
    if (_mode == _Mode.ask) {
      if (_answer != null) return _answerBody(_answer!);
      if (_noMatch != null) {
        return _empty(
          'No answer from your notes',
          '$_noMatch A question needs the words the take actually uses — its transcript '
              'and summary are what get searched, never the audio.',
        );
      }
      return _empty(
        'Ask a question across every take',
        '“What did we agree about the budget?”, “Who owns the sampling plan?”, '
            '“What should I review for the lecture?” — the answer cites the take and '
            'the moment it came from.',
      );
    }
    if (!_searched) {
      return _empty(
        'Find a word, a name or a project',
        'Search covers every word of every transcript and summary you have here. '
            'Open a result to hear the moment it was said.',
      );
    }
    if (_hits.isEmpty) {
      return _empty(
        'Nothing matches “${_controller.text.trim()}”',
        'Try a shorter phrase, a name, or the project the take is filed under.',
      );
    }
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: _hits.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final hit = _hits[i];
        return _HitRow(
          hit: hit,
          onTap: () => Navigator.of(context).pop(hit),
        );
      },
    );
  }

  Widget _answerBody(AskAnswer answer) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        const SizedBox(height: Tokens.s3),
        SelectableText(
          answer.answer,
          style: Tokens.body.copyWith(height: 1.55),
        ),
        const SizedBox(height: Tokens.s2),
        Row(
          children: [
            TextButton.icon(
              onPressed: () {
                // Copy is a convenience; the sheet stays open with the answer.
                Clipboard.setData(ClipboardData(text: answer.answer));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Answer copied'),
                    backgroundColor: Tokens.ink,
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy answer'),
            ),
          ],
        ),
        const SizedBox(height: Tokens.s2),
        const Divider(height: 1),
        const SizedBox(height: Tokens.s3),
        Text('Sources', style: Tokens.section),
        const SizedBox(height: Tokens.s2),
        for (var i = 0; i < answer.sources.length; i++)
          _SourceRow(
            index: i + 1,
            hit: answer.sources[i],
            onTap: () => Navigator.of(context).pop(answer.sources[i]),
          ),
        const SizedBox(height: Tokens.s4),
      ],
    );
  }

  Widget _empty(String title, String detail) {
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: Tokens.s3),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Tokens.body.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: Tokens.s1),
              Text(detail, style: Tokens.bodySmall),
              if (!_busy && takes.indexedTakes > 0) ...[
                const SizedBox(height: Tokens.s3),
                Wrap(
                  spacing: Tokens.s2,
                  runSpacing: Tokens.s2,
                  children: [
                    for (final example in const [
                      'sampling plan',
                      'what did we decide',
                    ])
                      ChoiceChipButton(
                        label: example,
                        compact: true,
                        selected: false,
                        icon: _mode == _Mode.ask ? Icons.chat_bubble_outline : Icons.search,
                        onTap: () => _useExample(example),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _HitRow extends StatelessWidget {
  const _HitRow({required this.hit, required this.onTap});
  final AskHit hit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${hit.title}, ${hit.stamp}. ${hit.text}',
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Tokens.s2, horizontal: Tokens.s1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 52,
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    hit.stamp,
                    style: Tokens.dataSmall.copyWith(color: Tokens.accent),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hit.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Tokens.body.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (hit.where.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(hit.where, style: Tokens.caption),
                      ),
                    const SizedBox(height: Tokens.s1),
                    Text(
                      hit.text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Tokens.bodySmall.copyWith(color: Tokens.ink.withValues(alpha: 0.86)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Tokens.s2),
              const Padding(
                padding: EdgeInsets.only(top: Tokens.s1),
                child: Icon(Icons.chevron_right, size: 18, color: Tokens.inkSoft),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.index, required this.hit, required this.onTap});
  final int index;
  final AskHit hit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cited = hit.cited;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Tokens.r1),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Tokens.s2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 30,
              child: Text(
                '[$index]',
                style: Tokens.dataSmall.copyWith(
                  color: cited ? Tokens.accent : Tokens.inkSoft,
                  fontWeight: cited ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(hit.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Tokens.body.copyWith(
                          fontWeight: cited ? FontWeight.w600 : FontWeight.w400)),
                  const SizedBox(height: 1),
                  Text(hit.where.isEmpty ? hit.stamp : '${hit.where} · ${hit.stamp}',
                      style: Tokens.caption),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkingLabel extends StatelessWidget {
  const _WorkingLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 2, color: Tokens.inkSoft),
        ),
        const SizedBox(width: Tokens.s2),
        Text(text),
      ],
    );
  }
}
