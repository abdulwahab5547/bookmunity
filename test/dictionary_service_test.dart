import 'dart:convert';

import 'package:bookmunity/core/db/app_database.dart';
import 'package:bookmunity/features/dictionary/dictionary_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _body = '''
[{"word":"rabbit","phonetic":"/ˈɹæbɪt/","meanings":[
  {"partOfSpeech":"noun","definitions":[{"definition":"A mammal of the family Leporidae.","example":"The rabbit hopped."}]},
  {"partOfSpeech":"verb","definitions":[{"definition":"To hunt rabbits."}]}]},
 {"word":"rabbit","meanings":[{"partOfSpeech":"noun","definitions":[{"definition":"A runner who sets the pace."}]}]}]
''';

void main() {
  test('parses and merges meanings by part of speech', () {
    final entry = DictionaryEntry.parse(_body)!;
    expect(entry.word, 'rabbit');
    expect(entry.phonetic, '/ˈɹæbɪt/');
    expect(entry.meanings.map((m) => m.partOfSpeech), ['noun', 'verb']);
    expect(entry.meanings.first.senses, hasLength(2));
    expect(entry.meanings.first.senses.first.example, 'The rabbit hopped.');
    expect(entry.shortDefinition, 'A mammal of the family Leporidae.');
  });

  test('rejects empty responses', () {
    expect(DictionaryEntry.parse('[]'), isNull);
    expect(DictionaryEntry.parse('{"title":"No Definitions Found"}'), isNull);
  });

  group('online phonetics', () {
    late AppDatabase database;
    setUp(() => database = AppDatabase(NativeDatabase.memory()));
    tearDown(() => database.close());

    test('fetches once, then serves from the cache offline', () async {
      final requested = <String>[];
      final online = OnlinePhonetics(
        database,
        client: MockClient((request) async {
          requested.add(request.url.pathSegments.last);
          return http.Response.bytes(utf8.encode(_body), 200);
        }),
      );
      expect(await online.phonetic('Rabbit'), '/ˈɹæbɪt/');
      expect(requested, ['rabbit']);

      final offline = OnlinePhonetics(
        database,
        client: MockClient((_) async => throw Exception('offline')),
      );
      expect(await offline.phonetic('rabbit'), '/ˈɹæbɪt/');
    });

    test('is silent when offline or not found', () async {
      final offline = OnlinePhonetics(
        database,
        client: MockClient((_) async => throw Exception('no network')),
      );
      expect(await offline.phonetic('gryphon'), isNull);
      final missing = OnlinePhonetics(
        database,
        client: MockClient((_) async => http.Response('{}', 404)),
      );
      expect(await missing.phonetic('zzzq'), isNull);
      expect(await missing.phonetic('look up'), isNull);
    });
  });
}
