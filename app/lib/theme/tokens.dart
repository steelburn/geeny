import 'package:flutter/material.dart';

/// Design tokens for the Geeny client.
///
/// Shared with `web/index.html` so the phone and the browser console read as the
/// same tool: paper stock, ink type, one forest accent, monotone data.
/// Direction: a field ledger for a pocket recorder — ruled paper, stamped state,
/// monospaced measurements.
class Tokens {
  Tokens._();

  // --- colour ---------------------------------------------------------------
  static const paper = Color(0xFFF5F3ED); // page
  static const surface = Color(0xFFFFFDF8); // raised stock (cards, sheets, inputs)
  static const ink = Color(0xFF1E2A24); // primary text
  static const inkSoft = Color(0xFF4F5A53); // secondary text
  static const rule = Color(0xFFD8D4C8); // ledger hairlines (decorative)
  static const ruleStrong = Color(0xFFA9A493); // edges that bound a control
  static const accent = Color(0xFF175C44); // forest — actions only
  static const accentPressed = Color(0xFF134A36);
  static const onAccent = Color(0xFFF7FBF8);
  static const accentSoft = Color(0xFFE3EDE7); // tint behind active rows
  static const danger = Color(0xFF7A3020);
  static const dangerSoft = Color(0xFFF6E7E3);
  static const warn = Color(0xFF7A5514);
  static const dotIdle = Color(0xFFB9B4A6);

  // --- spacing (4 px grid) --------------------------------------------------
  static const s1 = 4.0;
  static const s2 = 8.0;
  static const s3 = 12.0;
  static const s4 = 16.0;
  static const s5 = 24.0;
  static const s6 = 32.0;
  static const s7 = 48.0;

  // --- radius ---------------------------------------------------------------
  static const r1 = 4.0;
  static const r2 = 8.0;

  // --- touch ----------------------------------------------------------------
  /// Minimum comfortable target. Icon buttons and chips must not go below this.
  static const target = 48.0;
  static const targetCompact = 44.0;

  // --- type scale -----------------------------------------------------------
  //
  // Five sizes, two families. Everything in the app picks one of these; no
  // component invents its own size. Roles differ by weight, colour and family.
  //
  //   display 34 / title 20 / body 15 / small 13 / caption 12
  //
  static const sans = 'Spline Sans';
  static const mono = 'Spline Sans Mono';

  static const display = TextStyle(
    fontFamily: sans,
    fontSize: 34,
    height: 1.1,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.8,
    color: ink,
  );
  static const title = TextStyle(
    fontFamily: sans,
    fontSize: 20,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    color: ink,
  );

  /// Section label above a ruled block.
  static const section = TextStyle(
    fontFamily: sans,
    fontSize: 13,
    height: 1.2,
    fontWeight: FontWeight.w600,
    color: inkSoft,
  );

  static const body = TextStyle(
    fontFamily: sans,
    fontSize: 15,
    height: 1.5,
    fontWeight: FontWeight.w400,
    color: ink,
  );
  static const bodySmall = TextStyle(
    fontFamily: sans,
    fontSize: 13,
    height: 1.45,
    fontWeight: FontWeight.w400,
    color: inkSoft,
  );

  /// Smallest text in the app: metadata, counters, footnotes.
  static const caption = TextStyle(
    fontFamily: sans,
    fontSize: 12,
    height: 1.35,
    fontWeight: FontWeight.w400,
    color: inkSoft,
  );

  /// Every number, serial, hex dump and timestamp.
  static const data = TextStyle(
    fontFamily: mono,
    fontSize: 13,
    height: 1.45,
    fontWeight: FontWeight.w400,
    color: ink,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const dataSmall = TextStyle(
    fontFamily: mono,
    fontSize: 12,
    height: 1.4,
    fontWeight: FontWeight.w400,
    color: inkSoft,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  // --- elevation ------------------------------------------------------------
  //
  // Two levels, named by distance. A card sits on the paper (elev1); a sheet or
  // dialog is nearer the reader (elev2). Nothing else casts a shadow.
  static const List<BoxShadow> elev1 = [
    BoxShadow(color: Color(0x141E2A24), blurRadius: 2, offset: Offset(0, 1)),
  ];
  static const List<BoxShadow> elev2 = [
    BoxShadow(color: Color(0x1F1E2A24), blurRadius: 18, offset: Offset(0, 6)),
    BoxShadow(color: Color(0x141E2A24), blurRadius: 3, offset: Offset(0, 1)),
  ];
}
