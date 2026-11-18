import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qread/models/book.dart';
import 'package:qread/models/book_group.dart';
import 'package:qread/providers/bookshelf_provider.dart';
import 'package:qread/services/api_service.dart';
import 'package:qread/services/local_cache_service.dart';

void main() {
  late _ShelfApi api;
  late _ShelfCache cache;
  late BookshelfProvider provider;

  setUp(() {
    api = _ShelfApi();
    cache = _ShelfCache();
    provider = BookshelfProvider(api: api, cache: cache);
  });

  tearDown(() => provider.dispose());

  test('refresh keeps visible books until the replacement arrives', () async {
    await provider.loadBookshelf('test', refresh: true);
    final requested = Completer<void>();
    final response = Completer<List<Book>>();
    api.fetchBooks = (_) {
      requested.complete();
      return response.future;
    };

    final loading = provider.loadBookshelf('test', refresh: true);
    await requested.future;
    expect(provider.loading, isTrue);
    expect(provider.allBooks.single.bookUrl, 'old');

    response.complete([Book(bookUrl: 'new')]);
    await loading;
    expect(provider.allBooks.single.bookUrl, 'new');
    expect(provider.loading, isFalse);
  });

  test('refreshes during cache write are joined and coalesced', () async {
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    cache.nextWriteStarted = writeStarted;
    cache.nextWriteRelease = releaseWrite;
    var calls = 0;
    api.fetchBooks = (_) async => [Book(bookUrl: '${++calls}')];

    final first = provider.loadBookshelf('test', refresh: true);
    await writeStarted.future;
    var joinedFinished = false;
    final second = provider.loadBookshelf('test', refresh: true).then((_) {
      joinedFinished = true;
    });
    final third = provider.loadBookshelf('test', refresh: true);
    await Future<void>.value();

    expect(provider.allBooks.single.bookUrl, '1');
    expect(provider.loading, isTrue);
    expect(joinedFinished, isFalse);
    releaseWrite.complete();
    await Future.wait([first, second, third]);

    expect(api.pages, [1, 1]);
    expect(api.metadataCalls, 2);
    expect(provider.allBooks.single.bookUrl, '2');
    expect(cache.values['bookshelf_books_test_bookshelf']!.single['bookUrl'], '2');
    expect(joinedFinished, isTrue);
    expect(provider.loading, isFalse);
  });

  test('failed refresh preserves books and cache, then retry recovers', () async {
    await provider.loadBookshelf('test', refresh: true);
    final savedBooks = cache.values['bookshelf_books_test_bookshelf'];
    api.fetchBooks = (_) async => throw Exception('temporary failure');

    await provider.loadBookshelf('test', refresh: true);
    expect(provider.allBooks.single.bookUrl, 'old');
    expect(cache.values['bookshelf_books_test_bookshelf'], same(savedBooks));
    expect(provider.error, contains('temporary failure'));
    expect(provider.loading, isFalse);

    api.fetchBooks = (_) async => [Book(bookUrl: 'recovered')];
    await provider.loadBookshelf('test', refresh: true);
    expect(provider.allBooks.single.bookUrl, 'recovered');
    expect(provider.error, isNull);
  });

  test('first network page replaces cached books without duplicates', () async {
    cache.values['bookshelf_books_test_bookshelf'] = [
      Book(bookUrl: 'old').toJson(),
    ];
    await provider.loadBookshelf('test');
    expect(provider.allBooks.map((book) => book.bookUrl), ['old']);
  });

  test('failed refresh does not change the next page or snapshot md5', () async {
    api.totalPages = 2;
    await provider.loadBookshelf('test', refresh: true);
    api.md5 = 'new-snapshot';
    api.fetchBooks = (_) async => throw Exception('temporary failure');
    await provider.loadBookshelf('test', refresh: true);

    api.fetchBooks = (_) async => [Book(bookUrl: 'page-two')];
    await provider.loadBookshelf('test');
    expect(api.pages, [1, 1, 2]);
    expect(api.md5s, ['snapshot', 'new-snapshot', 'snapshot']);
    expect(provider.allBooks.map((book) => book.bookUrl),
        unorderedEquals(['old', 'page-two']));
    expect(provider.hasMore, isFalse);
  });

  test('an authoritative empty list clears books and cache', () async {
    await provider.loadBookshelf('test', refresh: true);
    api.fetchBooks = (_) async => [];
    await provider.loadBookshelf('test', refresh: true);
    expect(provider.allBooks, isEmpty);
    expect(cache.values['bookshelf_books_test_bookshelf'], isEmpty);
    expect(provider.error, isNull);
  });

  test('zero pages is an empty shelf, not a failed request', () async {
    await provider.loadBookshelf('test', refresh: true);
    api.totalPages = 0;
    await provider.loadBookshelf('test', refresh: true);
    expect(api.pages, [1]);
    expect(provider.allBooks, isEmpty);
    expect(provider.hasMore, isFalse);
    expect(provider.error, isNull);
  });

  test('malformed pagination preserves the previous shelf', () async {
    await provider.loadBookshelf('test', refresh: true);
    api.metadata = {'isSuccess': true, 'data': null};
    await provider.loadBookshelf('test', refresh: true);
    expect(provider.allBooks.single.bookUrl, 'old');
    expect(provider.error, isNotNull);
    expect(api.pages, [1]);
  });
}

class _ShelfApi extends Fake implements ApiService {
  int totalPages = 1;
  int metadataCalls = 0;
  String md5 = 'snapshot';
  Map<String, dynamic>? metadata;
  final pages = <int>[];
  final md5s = <String?>[];
  Future<List<Book>> Function(int) fetchBooks =
      (_) async => [Book(bookUrl: 'old')];

  @override
  Future<Map<String, dynamic>> getBookshelfPage(String accessToken) async {
    metadataCalls++;
    return metadata ??
        {
          'isSuccess': true,
          'data': {'md5': md5, 'page': totalPages},
        };
  }

  @override
  Future<List<Book>> getBookshelfNew(String accessToken,
      {String? md5, int page = 1}) {
    pages.add(page);
    md5s.add(md5);
    return fetchBooks(page);
  }

  @override
  Future<List<BookGroup>> getgroupNew(String accessToken, String md5) async => [];
}

class _ShelfCache extends Fake implements LocalCacheService {
  final values = <String, List<dynamic>>{};
  Completer<void>? nextWriteStarted;
  Completer<void>? nextWriteRelease;

  @override
  String scopedKey(String raw) => raw;

  @override
  Future<List<dynamic>?> readJsonList(String key) async => values[key];

  @override
  Future<void> saveJson(String key, Object data) async {
    final started = nextWriteStarted;
    final release = nextWriteRelease;
    nextWriteStarted = null;
    nextWriteRelease = null;
    started?.complete();
    if (release != null) await release.future;
    values[key] = data as List<dynamic>;
  }
}
