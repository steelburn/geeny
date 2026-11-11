import 'package:flutter/material.dart';

import 'state/session.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';
import 'ui/home_page.dart';

void main() {
  runApp(const GeenyApp());
}

class GeenyApp extends StatefulWidget {
  const GeenyApp({super.key, this.session});

  final Session? session;

  @override
  State<GeenyApp> createState() => _GeenyAppState();
}

class _GeenyAppState extends State<GeenyApp> {
  late final Session _session = widget.session ?? Session();

  @override
  void dispose() {
    if (widget.session == null) _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Geeny',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: HomePage(session: _session),
      builder: (context, child) => ColoredBox(
        color: Tokens.paper,
        child: MediaQuery.withClampedTextScaling(
          minScaleFactor: 0.9,
          maxScaleFactor: 1.4,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
  }
}
