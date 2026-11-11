import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geeny_app/state/takes.dart';

Take take(String name) => Take(
      file: File('/tmp/$name'),
      bytes: 1024,
      modified: DateTime(2026, 11, 11),
    );

void main() {
  final a = take('a.ogg');
  final b = take('b.ogg');
  final c = take('c.ogg');
  final items = [a, b, c];
  final projects = {a.file.path: 'Sampling', b.file.path: 'Work'};

  test('all returns everything', () {
    expect(filterTakes(items, projects, 'all'), items);
  });

  test('unfiled returns only takes without a project', () {
    expect(filterTakes(items, projects, 'unfiled'), [c]);
  });

  test('a project returns only its takes', () {
    expect(filterTakes(items, projects, 'Sampling'), [a]);
    expect(filterTakes(items, projects, 'Missing'), isEmpty);
  });
}
