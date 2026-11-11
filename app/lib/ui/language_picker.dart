import 'package:flutter/material.dart';

import '../ai/languages.dart';
import '../theme/tokens.dart';
import 'choice_chip.dart';
import 'widgets.dart';

/// Multi-select for the languages a recording may contain.
///
/// The chosen languages are shown as chips — tapping one removes it — and one
/// chip opens the full whisper list. Kept deliberately short: this sits above
/// the template picker in the notes sheet, where height is scarce.
///
/// The choice itself is owned by [AiSettings.speechLanguages] (app preferences),
/// so it is asked for once and remembered for later takes and later sessions.
class LanguagePicker extends StatelessWidget {
  const LanguagePicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  /// Whisper codes in choice order; empty means "let whisper detect".
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Tokens.s2,
      runSpacing: Tokens.s2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final code in selected)
          ChoiceChipButton(
            label: SpeechLanguages.nameOf(code) ?? code,
            compact: true,
            selected: true,
            onTap: () => onChanged([
              for (final c in selected)
                if (c != code) c,
            ]),
          ),
        ChoiceChipButton(
          label: 'Add language',
          compact: true,
          selected: false,
          icon: Icons.add,
          onTap: () => _open(context),
        ),
        if (selected.isNotEmpty)
          ChoiceChipButton(
            label: 'Auto · detect',
            compact: true,
            selected: false,
            onTap: () => onChanged(const []),
          ),
      ],
    );
  }

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LanguageSheet(initial: selected),
    );
    if (picked != null) onChanged(picked);
  }
}

class _LanguageSheet extends StatefulWidget {
  const _LanguageSheet({required this.initial});
  final List<String> initial;

  @override
  State<_LanguageSheet> createState() => _LanguageSheetState();
}

class _LanguageSheetState extends State<_LanguageSheet> {
  late final List<String> _picked = [...widget.initial];
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _toggle(String code) {
    setState(() {
      if (!_picked.remove(code)) _picked.add(code);
    });
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final entries = [
      for (final e in whisperLanguages.entries)
        if (query.isEmpty ||
            e.value.toLowerCase().contains(query) ||
            e.key.contains(query))
          e,
    ];
    return SheetSurface(
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            Tokens.s5,
            Tokens.s4,
            Tokens.s5,
            Tokens.s4 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(child: Text('Languages', style: Tokens.title)),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(_picked),
                    child: const Text('Done'),
                  ),
                ],
              ),
              Text(
                _picked.isEmpty
                    ? 'Whisper will work out the language itself.'
                    : _picked.length == 1
                        ? '${SpeechLanguages.nameOf(_picked.first) ?? _picked.first} is '
                            'forced, so whisper does not have to guess.'
                        : 'Whisper detects across the take; the first one you picked '
                            '(${SpeechLanguages.nameOf(_picked.first) ?? _picked.first}) is the '
                            'fallback when its guess is outside this list.',
                style: Tokens.caption,
              ),
              const SizedBox(height: Tokens.s3),
              TextField(
                controller: _search,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) => setState(() {}),
                style: Tokens.data,
                decoration: const InputDecoration(hintText: 'Search languages'),
              ),
              const SizedBox(height: Tokens.s3),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.45,
                ),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: Tokens.s2,
                    runSpacing: Tokens.s2,
                    children: [
                      ChoiceChipButton(
                        label: 'Auto · detect',
                        compact: true,
                        selected: _picked.isEmpty,
                        onTap: () => setState(_picked.clear),
                      ),
                      for (final e in entries)
                        ChoiceChipButton(
                          label: e.value,
                          compact: true,
                          selected: _picked.contains(e.key),
                          onTap: () => _toggle(e.key),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
