import 'package:flutter_test/flutter_test.dart';
import 'package:qread/models/book.dart';
import 'package:qread/models/book_source.dart';
import 'package:qread/models/search_result.dart';

void main() {
  group('book type JSON contract', () {
    final cases = <Object?, int?>{
      null: null,
      0: 0,
      1: 1,
      2: 2,
      3: 3,
      32: 1,
      64: 2,
      '0': 0,
      '1': 1,
      '2': 2,
      '3': 3,
      '32': 1,
      '64': 2,
      -1: 0,
      4: 0,
      96: 0,
      128: 0,
      256: 0,
      '128': 0,
      'invalid': 0,
      '': 0,
      true: 0,
      false: 0,
      32.5: 0,
      double.infinity: 0,
    };

    for (final entry in cases.entries) {
      test('${entry.key} (${entry.key.runtimeType}) normalizes consistently', () {
        final json = <String, dynamic>{'type': entry.key};
        final result = SearchResult.fromJson(json);
        final book = Book.fromJson(json);

        expect(result.type, entry.value);
        expect(book.type, entry.value);
        expect(result.toJson(), containsPair('type', entry.value));
        expect(book.toJson(), containsPair('type', entry.value));
        expect(SearchResult.fromJson(result.toJson()).type, entry.value);
        expect(Book.fromJson(book.toJson()).type, entry.value);
        expect(result.toBook().type, entry.value ?? 0);
      });
    }

    test('omitted types stay nullable until conversion to Book', () {
      final result = SearchResult.fromJson(<String, dynamic>{});
      expect(result.type, isNull);
      expect(Book.fromJson(<String, dynamic>{}).type, isNull);
      expect(SearchResult.fromJson(result.toJson()).type, isNull);
      expect(result.toBook().type, 0);
      expect(result.type, isNull);
    });

    test('whole-number doubles use the same contract', () {
      expect(SearchResult.fromJson({'type': 32.0}).type, 1);
      expect(Book.fromJson({'type': 64.0}).type, 2);
    });
  });

  group('SearchResult to Book', () {
    test('preserves metadata and media type through cache and save payloads', () {
      final result = SearchResult(
        bookUrl: 'https://books.test/book',
        name: 'A book',
        author: 'An author',
        coverUrl: 'https://books.test/cover',
        intro: 'Introduction',
        kind: 'Category',
        latestChapterTitle: 'Latest chapter',
        tocUrl: 'https://books.test/toc',
        origin: 'https://books.test',
        originName: 'A source',
        wordCount: '10万字',
        type: 2,
      );
      final cached = SearchResult.fromJson(result.toJson());
      final book = cached.toBook();
      for (final entry in result.toJson().entries) {
        expect(book.toJson(), containsPair(entry.key, entry.value));
      }
      expect(book.group, 0);
      expect(Book.fromJson(book.toJson()).type, 2);
    });

    test('also normalizes types passed directly to the constructor', () {
      for (final entry in {0: 0, 1: 1, 2: 2, 3: 3, 32: 1, 64: 2, 128: 0}.entries) {
        expect(SearchResult(type: entry.key).toBook().type, entry.value);
      }
    });

    test('missing types use the matching source type', () {
      for (final entry in {0: 0, 1: 1, 2: 2, 3: 3}.entries) {
        final source = BookSource.fromJson({
          'bookSourceUrl': 'https://books.test',
          'bookSourceType': entry.key,
        });
        final result = SearchResult(origin: source.bookSourceUrl);
        expect(result.toBook(source: source).type, entry.value);
        expect(result.type, isNull);
      }
    });

    test('a known discovery source can fill an omitted result origin', () {
      final source = BookSource(
        bookSourceUrl: 'https://books.test',
        bookSourceType: 2,
      );
      expect(SearchResult().toBook(source: source).type, 2);
    });

    test('explicit result types, including text, always beat the source', () {
      final source = BookSource(
        bookSourceUrl: 'https://books.test',
        bookSourceType: 1,
      );
      for (final entry in {0: 0, 1: 1, 2: 2, 3: 3, 32: 1, 64: 2, 128: 0}.entries) {
        final result = SearchResult(type: entry.key, origin: source.bookSourceUrl);
        expect(result.toBook(source: source).type, entry.value);
      }
      final invalid = SearchResult.fromJson({'type': 'invalid'});
      expect(invalid.toBook(source: source).type, 0);
    });

    test('mismatched or unidentified sources do not supply a type', () {
      final result = SearchResult(origin: 'https://books.test');
      for (final url in <String?>[null, '', 'https://other.test']) {
        final source = BookSource(bookSourceUrl: url, bookSourceType: 2);
        expect(result.toBook(source: source).type, 0);
      }
    });

    test('audio-only sources are detected by name when the type is text', () {
      for (final name in ['听书大全', '有声书聚合']) {
        final source = BookSource(
          bookSourceUrl: 'https://books.test',
          bookSourceName: name,
        );
        final result = SearchResult(origin: source.bookSourceUrl);
        expect(result.toBook(source: source).type, 1);
        expect(
          SearchResult(type: 2, origin: source.bookSourceUrl)
              .toBook(source: source)
              .type,
          2,
        );
        expect(SearchResult().toBook().type, 0);
      }
      final novel = BookSource(
        bookSourceUrl: 'https://books.test',
        bookSourceName: '书香小说',
      );
      expect(SearchResult().toBook(source: novel).type, 0);
    });

    test('missing and unknown source types do not invent a media type', () {
      for (final type in <int?>[null, -1, 4, 32, 64, 128]) {
        final source = BookSource(
          bookSourceUrl: 'https://books.test',
          bookSourceType: type,
        );
        expect(SearchResult().toBook(source: source).type, 0);
      }
      expect(
        SearchResult(name: '漫画', bookUrl: 'https://books.test/audio.mp3')
            .toBook()
            .type,
        0,
      );
    });
  });
}
