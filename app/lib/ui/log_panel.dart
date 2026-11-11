import 'package:flutter/material.dart';

import '../state/session.dart';
import '../theme/tokens.dart';

class LogPanel extends StatefulWidget {
  const LogPanel({super.key, required this.session});
  final Session session;

  @override
  State<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<LogPanel> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant LogPanel old) {
    super.didUpdateWidget(old);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.session.log;
    return Container(
      decoration: BoxDecoration(
        color: Tokens.surface,
        borderRadius: BorderRadius.circular(Tokens.r2),
        border: Border.all(color: Tokens.rule),
        boxShadow: Tokens.elev1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Ledger head: the column titles that every row lines up to.
          Padding(
            padding: const EdgeInsets.fromLTRB(Tokens.s3, Tokens.s2, Tokens.s3, Tokens.s2),
            child: Row(
              children: [
                SizedBox(
                  width: 38,
                  child: Text('dir', style: Tokens.dataSmall.copyWith(color: Tokens.inkSoft)),
                ),
                Expanded(
                  child: Text('frame', style: Tokens.dataSmall.copyWith(color: Tokens.inkSoft)),
                ),
                SizedBox(
                  width: 64,
                  child: Text(
                    'time',
                    textAlign: TextAlign.right,
                    style: Tokens.dataSmall.copyWith(color: Tokens.inkSoft),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: lines.isEmpty
                ? const _EmptyLog()
                : ListView.separated(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(vertical: Tokens.s1),
                    itemCount: lines.length,
                    separatorBuilder: (_, _) => const Divider(
                      height: 1,
                      color: Color(0x14000000),
                      indent: Tokens.s3,
                      endIndent: Tokens.s3,
                    ),
                    itemBuilder: (_, i) => _LogRow(line: lines[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.line});
  final LogLine line;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (line.kind) {
      LogKind.tx => ('tx', Tokens.accent),
      LogKind.rx => ('rx', Tokens.ink),
      LogKind.note => ('·', Tokens.inkSoft),
      LogKind.error => ('!!', Tokens.danger),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Tokens.s3, vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 38,
            child: Text(label, style: Tokens.dataSmall.copyWith(color: color, fontWeight: FontWeight.w500)),
          ),
          Expanded(
            child: Text(
              line.text,
              style: Tokens.dataSmall.copyWith(color: color == Tokens.inkSoft ? Tokens.inkSoft : Tokens.ink),
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(
              line.stamp,
              textAlign: TextAlign.right,
              style: Tokens.dataSmall.copyWith(color: Tokens.inkSoft),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyLog extends StatelessWidget {
  const _EmptyLog();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Tokens.s5, Tokens.s5, Tokens.s5, Tokens.s4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Nothing logged yet.', style: Tokens.body.copyWith(color: Tokens.inkSoft)),
          const SizedBox(height: Tokens.s2),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Text(
              'Every frame the recorder sends lands here — handshakes, replies and transfer chunks. '
              'Press Connect to start.',
              style: Tokens.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
