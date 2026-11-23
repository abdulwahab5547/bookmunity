import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'discover_models.dart';

/// HTTP for catalogue requests: a polite User-Agent, timeouts, friendly
/// errors and an in-memory cache for the session.
class DiscoverHttp {
  DiscoverHttp({
    http.Client? client,
    this.cacheFor = const Duration(minutes: 30),
  }) : client = client ?? http.Client();

  static const userAgent = 'Bookmunity/1.0 (ebook reader app)';

  final http.Client client;
  final Duration cacheFor;
  final _cache = <String, ({DateTime at, String body})>{};
  final _inFlight = <String, Future<String>>{};

  Map<String, String> get headers => const {
    'User-Agent': userAgent,
    'Accept-Language': 'en',
  };

  /// GETs [url] as text. Repeated calls within [cacheFor] are served from
  /// memory; concurrent calls share one request.
  Future<String> getText(
    Uri url, {
    Duration timeout = const Duration(seconds: 25),
    String? accept,
  }) {
    final key = url.toString();
    final cached = _cache[key];
    if (cached != null && DateTime.now().difference(cached.at) < cacheFor) {
      return Future.value(cached.body);
    }
    return _inFlight[key] ??= _fetch(url, timeout, accept)
        .then((body) {
          _cache[key] = (at: DateTime.now(), body: body);
          return body;
        })
        .whenComplete(() {
          // A block body: returning the removed future would make
          // whenComplete wait on itself.
          _inFlight.remove(key);
        });
  }

  Future<dynamic> getJson(
    Uri url, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final body = await getText(
      url,
      timeout: timeout,
      accept: 'application/json',
    );
    try {
      return jsonDecode(body);
    } on FormatException {
      throw DiscoverSourceException('${url.host} sent an unexpected answer.');
    }
  }

  /// Size of a file from a HEAD request, or null when unknown.
  Future<int?> contentLength(Uri url) async {
    try {
      final response = await client
          .head(url, headers: headers)
          .timeout(const Duration(seconds: 12));
      if (response.statusCode >= 400) return null;
      return int.tryParse(response.headers['content-length'] ?? '');
    } catch (_) {
      return null;
    }
  }

  void clearCache() => _cache.clear();

  Future<String> _fetch(Uri url, Duration timeout, String? accept) async {
    final http.Response response;
    try {
      response = await client
          .get(url, headers: {...headers, 'Accept': ?accept})
          .timeout(timeout);
    } on TimeoutException {
      throw DiscoverSourceException(
        '${_name(url)} is taking too long to answer.',
      );
    } on http.ClientException catch (error) {
      if (_looksOffline(error.message)) throw const DiscoverOfflineException();
      throw DiscoverSourceException('${_name(url)} could not be reached.');
    }
    if (response.statusCode == 503 || response.statusCode == 502) {
      throw DiscoverSourceException(
        '${_name(url)} is temporarily unavailable.',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode >= 400) {
      throw DiscoverSourceException(
        '${_name(url)} answered with an error (${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  static bool _looksOffline(String message) {
    final lower = message.toLowerCase();
    return lower.contains('failed host lookup') ||
        lower.contains('network is unreachable') ||
        lower.contains('no address associated') ||
        lower.contains('internet connection appears to be offline') ||
        lower.contains('xmlhttprequest error');
  }

  static String _name(Uri url) => switch (url.host) {
    'gutendex.com' || 'www.gutenberg.org' => 'Project Gutenberg',
    'standardebooks.org' => 'Standard Ebooks',
    'openlibrary.org' => 'Open Library',
    'archive.org' => 'The Internet Archive',
    _ => url.host,
  };
}
