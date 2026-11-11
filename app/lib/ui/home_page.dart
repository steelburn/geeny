import 'package:flutter/material.dart';

import '../state/session.dart';
import '../theme/tokens.dart';
import 'ai_settings_section.dart';
import 'disclosure.dart';
import 'log_panel.dart';
import 'takes_section.dart';
import 'widgets.dart';

/// The whole app is two things: record, and the takes you have. Everything that
/// is setup or diagnosis lives in the side panel until it is needed.
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.session});

  final Session session;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _drawerOpen = false;

  Session get session => widget.session;

  @override
  Widget build(BuildContext context) {
    // Back must close the Setup panel before it leaves the app.
    return PopScope(
      canPop: !_drawerOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _drawerOpen) Navigator.of(context).pop();
      },
      child: Scaffold(
        onEndDrawerChanged: (open) => setState(() => _drawerOpen = open),
        endDrawer: _SetupPanel(session: session),
        body: SafeArea(
          child: AnimatedBuilder(
            animation: session,
            builder: (context, _) {
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1080),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(Tokens.s5, Tokens.s4, Tokens.s5, Tokens.s4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Header(session: session),
                        const SizedBox(height: Tokens.s4),
                        const Divider(height: 1),
                        const SizedBox(height: Tokens.s4),
                        _Actions(session: session),
                        SizedBox(
                          height: session.error == null ? Tokens.s3 : 62,
                          child: session.error == null
                              ? null
                              : ErrorStrip(
                                  message: session.error!,
                                  onDismiss: session.dismissError,
                                ),
                        ),
                        _StatusBar(session: session),
                        const SizedBox(height: Tokens.s4),
                        Expanded(
                          child: TakesSection(
                            takes: session.takes,
                            playingPath: session.takes.current?.file.path,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final (state, label) = switch (session.linkState) {
      LinkState.offline => ('offline', 'offline'),
      LinkState.scanning => ('scanning', session.busy == 'connect' ? 'connecting…' : 'scanning…'),
      LinkState.connected => ('connected', session.info?.name ?? 'connected'),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text('Notra', style: Tokens.display),
                Text('.', style: Tokens.display.copyWith(color: Tokens.accent)),
              ],
            ),
            const SizedBox(height: Tokens.s1),
            Text(
              session.connected
                  ? (session.info?.serial.isNotEmpty ?? false)
                      ? 'Recorder ${session.info!.serial}'
                      : 'Recorder connected'
                  : 'Your recorder, over Bluetooth.',
              style: Tokens.bodySmall,
            ),
          ],
        ),
        const Spacer(),
        if (session.battery != null) ...[
          _BatteryChip(percent: session.battery!),
          const SizedBox(width: Tokens.s3),
        ],
        StatusPill(state: state, label: label),
        const SizedBox(width: Tokens.s2),
        Builder(
          builder: (ctx) => IconButton(
            onPressed: () => Scaffold.of(ctx).openEndDrawer(),
            tooltip: 'Setup',
            constraints: const BoxConstraints(
              minWidth: Tokens.target,
              minHeight: Tokens.target,
            ),
            icon: const Icon(Icons.tune, size: 20, color: Tokens.inkSoft),
          ),
        ),
      ],
    );
  }
}

class _BatteryChip extends StatelessWidget {
  const _BatteryChip({required this.percent});
  final int percent;

  @override
  Widget build(BuildContext context) {
    final low = percent <= 20;
    return Semantics(
      label: 'Recorder battery $percent percent',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(low ? Icons.battery_alert : Icons.battery_std,
              size: 16, color: low ? Tokens.danger : Tokens.inkSoft),
          const SizedBox(width: Tokens.s1),
          Text('$percent%',
              style: Tokens.dataSmall.copyWith(color: low ? Tokens.danger : Tokens.inkSoft)),
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final busy = session.busy;
    final connected = session.connected;
    final idle = connected && busy == null;
    return Wrap(
      spacing: Tokens.s2,
      runSpacing: Tokens.s2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (!connected)
          FilledButton(
            onPressed: busy == null ? session.connect : null,
            child: Text(session.linkState == LinkState.scanning ? 'Scanning…' : 'Connect'),
          )
        else ...[
          FilledButton(
            onPressed: idle ? session.recordToggle : null,
            child: busy == 'record'
                ? _BusyLabel(session.recording ? 'Stopping…' : 'Starting…')
                : Text(session.recording ? 'Stop recording' : 'Record'),
          ),
          OutlinedButton(
            onPressed: idle ? session.pullLatest : null,
            child: busy == 'pull' ? const _BusyLabel('Fetching…') : const Text('Fetch latest'),
          ),
          OutlinedButton(
            onPressed: busy == null ? session.disconnect : null,
            child: const Text('Disconnect'),
          ),
        ],
      ],
    );
  }
}

/// One compact line about the recorder, expanding only while something is
/// happening. Idle it is a bar, not an empty card.
class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final active = session.recording;
    final t = session.transfer;
    final notice = session.notice;
    final busyTransfer = t != null;
    final tall = active || busyTransfer || notice != null;

    final detail = switch (true) {
      _ when active => Session.clock(session.elapsed),
      _ when session.connected => session.info?.serial.isNotEmpty == true
          ? 'Recorder ${session.info!.serial}'
          : 'Recorder connected',
      _ => 'Tap Connect to pair',
    };

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Tokens.s4,
        vertical: tall ? Tokens.s3 : Tokens.s2,
      ),
      decoration: BoxDecoration(
        color: active ? Tokens.accentSoft : Tokens.surface,
        borderRadius: BorderRadius.circular(Tokens.r2),
        border: Border.all(color: active ? Tokens.accent : Tokens.rule),
        boxShadow: Tokens.elev1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: active ? Tokens.danger : Tokens.dotIdle,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: Tokens.s2),
              Text(
                active
                    ? 'Recording'
                    : session.connected
                        ? 'Ready'
                        : 'Not connected',
                style: Tokens.body.copyWith(fontWeight: FontWeight.w600),
              ),
              if (active) ...[
                const SizedBox(width: Tokens.s3),
                Text(detail, style: Tokens.data.copyWith(fontWeight: FontWeight.w500)),
              ] else ...[
                const SizedBox(width: Tokens.s3),
                Flexible(
                  child: Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Tokens.dataSmall,
                  ),
                ),
              ],
              if (session.storageLabel != null) ...[
                const SizedBox(width: Tokens.s3),
                Semantics(
                  label: 'Recorder storage: ${session.storageLabel} free of '
                      '${session.storageTotalLabel}',
                  child: Tooltip(
                    message: '${session.storageTotalLabel} total on the recorder',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.sd_storage_outlined,
                            size: 14, color: Tokens.inkSoft),
                        const SizedBox(width: Tokens.s1),
                        Text('${session.storageLabel} free', style: Tokens.dataSmall),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (notice != null) ...[
            const SizedBox(height: Tokens.s1),
            Text(
              notice,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Tokens.bodySmall.copyWith(color: Tokens.ink),
            ),
          ],
          if (busyTransfer) ...[
            const SizedBox(height: Tokens.s2),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: t.total > 0 ? t.fraction : null,
                minHeight: 3,
                backgroundColor: Tokens.rule,
                color: Tokens.accent,
              ),
            ),
            const SizedBox(height: Tokens.s1),
            Text(
              t.total > 0
                  ? '${_kb(t.offset)} of ${_kb(t.total)}'
                  : '${_kb(t.offset)} received',
              style: Tokens.dataSmall,
            ),
          ],
        ],
      ),
    );
  }

  static String _kb(int bytes) =>
      bytes < 1024 ? '$bytes B' : '${(bytes / 1024).toStringAsFixed(1)} kB';
}

/// Right-hand side panel: everything that is not recording or playing.
class _SetupPanel extends StatelessWidget {
  const _SetupPanel({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: Tokens.paper,
      width: 420,
      child: SafeArea(
        child: AnimatedBuilder(
          animation: session,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.fromLTRB(Tokens.s4, Tokens.s4, Tokens.s4, Tokens.s5),
            children: [
              Row(
                children: [
                  Text('Setup', style: Tokens.title),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    constraints: const BoxConstraints(
                      minWidth: Tokens.target,
                      minHeight: Tokens.target,
                    ),
                    icon: const Icon(Icons.close, size: 20, color: Tokens.inkSoft),
                    tooltip: 'Close',
                  ),
                ],
              ),
              const SizedBox(height: Tokens.s2),
              _DeviceSettings(session: session),
              const SizedBox(height: Tokens.s5),
              Disclosure(
                title: 'Transcription',
                trailing: Text(
                  session.takes.aiSettings.routingLabel,
                  style: Tokens.dataSmall,
                ),
                initiallyOpen: true,
                child: AiSettingsSection(takes: session.takes),
              ),
              const SizedBox(height: Tokens.s5),
              _Diagnostics(session: session),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceSettings extends StatelessWidget {
  const _DeviceSettings({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final connected = session.connected;
    final editable = connected && session.busy == null;
    return Disclosure(
      title: 'Recorder settings',
      trailing: Text(connected ? 'applied immediately' : 'offline', style: Tokens.dataSmall),
      initiallyOpen: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SettingRow(
            label: 'Mic sensitivity',
            value: '${session.gain} dB',
            onMinus: editable && session.gain > 0 ? () => session.applyGain(session.gain - 1) : null,
            onPlus: editable && session.gain < 30 ? () => session.applyGain(session.gain + 1) : null,
            hint: 'Higher picks up more room, lower keeps voices clean.',
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: session.noiseReduction,
            onChanged: editable ? (v) => session.toggleNoiseReduction(v) : null,
            title: Text('Noise reduction', style: Tokens.body),
            subtitle: Text('Clean up background noise while recording.', style: Tokens.caption),
            activeThumbColor: Tokens.accent,
          ),
          _SettingRow(
            label: 'Voice pickup (VCS)',
            value: '${session.vcsLevel}',
            onMinus: editable && session.vcsLevel > 0 ? () => session.setVcsGain(session.vcsLevel - 1) : null,
            onPlus: editable && session.vcsLevel < 3 ? () => session.setVcsGain(session.vcsLevel + 1) : null,
            hint: 'Gain for the vibration sensor, for calls. Not every firmware accepts it.',
          ),
          if (session.settingsNote != null) ...[
            const SizedBox(height: Tokens.s2),
            Text(session.settingsNote!,
                style: Tokens.bodySmall.copyWith(color: Tokens.danger)),
          ],
          const SizedBox(height: Tokens.s3),
          Wrap(
            spacing: Tokens.s2,
            runSpacing: Tokens.s2,
            children: [
              OutlinedButton(
                  onPressed: editable ? session.arm : null,
                  child: const Text('Arm for official app')),
              OutlinedButton(
                  onPressed: editable ? session.deactivate : null,
                  child: const Text('Hand back to official app')),
              TextButton(
                  onPressed: editable ? session.refreshSettings : null,
                  child: const Text('Refresh')),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.label,
    required this.value,
    required this.onMinus,
    required this.onPlus,
    this.hint,
  });

  final String label;
  final String value;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Tokens.s2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Tokens.body),
                if (hint != null) Text(hint!, style: Tokens.caption),
              ],
            ),
          ),
          const SizedBox(width: Tokens.s2),
          Text(value, style: Tokens.data.copyWith(fontWeight: FontWeight.w500)),
          const SizedBox(width: Tokens.s2),
          _StepButton(glyph: '−', tooltip: 'Decrease $label', onPressed: onMinus),
          const SizedBox(width: Tokens.s1),
          _StepButton(glyph: '+', tooltip: 'Increase $label', onPressed: onPlus),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.glyph, required this.tooltip, required this.onPressed});
  final String glyph;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: Tokens.targetCompact,
        height: Tokens.targetCompact,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(Tokens.targetCompact, Tokens.targetCompact),
            textStyle: Tokens.data.copyWith(fontWeight: FontWeight.w500),
          ),
          child: Text(glyph),
        ),
      ),
    );
  }
}

class _Diagnostics extends StatelessWidget {
  const _Diagnostics({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final info = session.info;
    final errors = session.log.where((l) => l.kind == LogKind.error).length;
    return Disclosure(
      title: 'Diagnostics',
      trailing: Text(
        session.connected ? '${session.receivedCount} frames in' : 'offline',
        style: Tokens.dataSmall,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Fact(label: 'name', value: info?.name ?? '', emphasis: true),
          Fact(label: 'serial', value: info?.serial ?? ''),
          Fact(label: 'address', value: session.address),
          Fact(label: 'mtu', value: session.mtu > 0 ? '${session.mtu} B' : ''),
          Fact(label: 'battery', value: session.battery == null ? '' : '${session.battery} %'),
          Fact(
            label: 'storage',
            value: session.storageFreeKb == null
                ? ''
                : '${session.storageLabel} free of ${session.storageTotalLabel}',
          ),
          Fact(label: 'sent', value: '${session.sentCount} frames'),
          Fact(label: 'received', value: '${session.receivedCount} frames'),
          Fact(label: 'errors', value: '$errors'),
          Fact(label: 'dropped frames', value: '${session.corruptFrames}'),
          const SizedBox(height: Tokens.s1),
          Text(
            'Mic sensitivity is attribute 0x04 on channel 0x001e; noise reduction is '
            '0x05; recording is 0x16.',
            style: Tokens.caption,
          ),
          const SizedBox(height: Tokens.s3),
          Wrap(
            spacing: Tokens.s2,
            runSpacing: Tokens.s2,
            children: [
              OutlinedButton(
                onPressed: session.connected && session.busy == null ? session.readDevice : null,
                child: const Text('Read device'),
              ),
              OutlinedButton(
                onPressed: session.connected && session.busy == null ? session.heartbeat : null,
                child: const Text('Heartbeat'),
              ),
              TextButton(
                onPressed: session.log.isEmpty ? null : session.clearLog,
                child: const Text('Clear log'),
              ),
            ],
          ),
          const SizedBox(height: Tokens.s3),
          SizedBox(height: 220, child: LogPanel(session: session)),
        ],
      ),
    );
  }
}

class _BusyLabel extends StatelessWidget {
  const _BusyLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
            width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Tokens.inkSoft)),
        const SizedBox(width: Tokens.s2),
        Text(text),
      ],
    );
  }
}
