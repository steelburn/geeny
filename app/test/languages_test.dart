import 'package:flutter_test/flutter_test.dart';
import 'package:geeny_app/ai/ai_settings.dart';
import 'package:geeny_app/ai/languages.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the language catalogue', () {
    test('folds dialects to their base code and finds the name', () {
      expect(SpeechLanguages.normalise('EN-gb'), 'en');
      expect(SpeechLanguages.normalise('pt_BR'), 'pt');
      expect(SpeechLanguages.nameOf('de-AT'), 'German');
      expect(SpeechLanguages.nameOf('xx'), isNull);
    });

    test('sanitise keeps choice order and drops duplicates and inventions', () {
      expect(
        SpeechLanguages.sanitise(['DE', 'en-GB', 'de', 'klingon', '', null, 'en']),
        ['de', 'en'],
      );
      expect(SpeechLanguages.sanitise(const []), isEmpty);
    });

    test('one language is forced, several are left to detection', () {
      expect(SpeechLanguages.forceFor(const []), '');
      expect(SpeechLanguages.forceFor(const ['de']), 'de');
      expect(SpeechLanguages.forceFor(const ['de', 'en']), '');
    });

    test('a detection is covered by code, by name, or by dialect', () {
      expect(SpeechLanguages.covers(const [], 'fr'), isTrue);
      expect(SpeechLanguages.covers(const ['de', 'en'], 'en'), isTrue);
      expect(SpeechLanguages.covers(const ['de', 'en'], 'English'), isTrue);
      expect(SpeechLanguages.covers(const ['de', 'en'], 'en-US'), isTrue);
      // A guess outside the list is what earns the fallback pass.
      expect(SpeechLanguages.covers(const ['de', 'en'], 'fr'), isFalse);
      expect(SpeechLanguages.covers(const ['de'], ''), isFalse);
    });

    test('describe names the choice, or says auto', () {
      expect(SpeechLanguages.describe(const []), 'auto');
      expect(SpeechLanguages.describe(const ['de', 'en']), 'German, English');
    });
  });

  group('remembered across sessions', () {
    test('the chosen languages survive a reload, in the order chosen', () async {
      final settings = AiSettings();
      await settings.load();
      expect(settings.speechLanguages, isEmpty);
      expect(settings.speechLanguagesLabel, 'auto');

      settings.setSpeechLanguages(const ['de', 'EN-gb', 'de', 'nope']);
      await settings.save();

      final reloaded = AiSettings();
      await reloaded.load();
      expect(reloaded.speechLanguages, ['de', 'en']);
      expect(reloaded.speechLanguagesLabel, 'German, English');
    });

    test('a retired or hand-edited code is ignored instead of sent on the wire', () async {
      SharedPreferences.setMockInitialValues({
        'ai.speechLanguages': ['de', 'klingon', 'EN'],
      });
      final settings = AiSettings();
      await settings.load();
      expect(settings.speechLanguages, ['de', 'en']);
    });

    test('a list that folds to the same codes is not stored twice', () async {
      final settings = AiSettings();
      await settings.load();

      settings.setSpeechLanguages(const ['de']);
      expect(settings.speechLanguages, ['de']);

      // Same choice spelled differently: sanitising leaves the state as it was.
      settings.setSpeechLanguages(const ['DE', 'de']);
      expect(settings.speechLanguages, ['de']);

      settings.setSpeechLanguages(const ['de', 'en']);
      expect(settings.speechLanguages, ['de', 'en']);
    });
  });
}
