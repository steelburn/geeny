import 'package:flutter/material.dart';

import 'state/session.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';
import 'ui/home_page.dart';

void main() {
  runApp(const NotraApp());
}

class NotraApp extends StatefulWidget {
  const NotraApp({super.key, this.session});

  final Session? session;

  @override
  State<NotraApp> createState() => _NotraAppState();
}

class _NotraAppState extends State<NotraApp> {
  late final Session _session = widget.session ?? Session();

  @override
  void dispose() {
    if (widget.session == null) _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Notra',
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
