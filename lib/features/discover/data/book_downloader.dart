import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'discover_http.dart';
import 'discover_models.dart';

class DownloadedBook {
  const DownloadedBook({
    required this.bytes,
    required this.url,
    required this.format,
  });

  final Uint8List bytes;

  /// The URL that worked; stored as the book's source URL.
  final String url;
  final BookFormat format;
}

class DownloadCancelled implements Exception {
  const DownloadCancelled();

  @override
  String toString() => 'Download cancelled.';
}

class DownloadCancelToken {
  final _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;

  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

typedef DownloadProgress = void Function(int received, int? total);

/// Streams a book file to memory with progress and cancellation, trying
/// mirrors in order, and checks that what arrived is really an EPUB or PDF.
class BookDownloader {
  BookDownloader({http.Client? client}) : client = client ?? http.Client();

  final http.Client client;

  /// A download that receives nothing for this long is abandoned.
  static const stallTimeout = Duration(seconds: 60);

  /// Refuse files larger than this; they would not fit in memory on many
  /// phones.
  static const maxBytes = 200 * 1024 * 1024;

  Future<DownloadedBook> download(
    DownloadOption option, {
    DownloadProgress? onProgress,
    DownloadCancelToken? cancelToken,
  }) async {
    Object? lastError;
    for (final url in option.urls) {
      if (cancelToken?.isCancelled ?? false) throw const DownloadCancelled();
      try {
        final bytes = await _fetch(Uri.parse(url), onProgress, cancelToken);
        validate(bytes, option.format);
        return DownloadedBook(bytes: bytes, url: url, format: option.format);
      } on DownloadCancelled {
        rethrow;
      } on DiscoverOfflineException {
        rethrow;
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? const DiscoverSourceException('Download failed.');
  }

  Future<Uint8List> _fetch(
    Uri url,
    DownloadProgress? onProgress,
    DownloadCancelToken? cancelToken,
  ) async {
    final request = http.AbortableRequest(
      'GET',
      url,
      abortTrigger: cancelToken?.whenCancelled,
    )..headers['User-Agent'] = DiscoverHttp.userAgent;
    final http.StreamedResponse response;
    try {
      response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
    } on http.RequestAbortedException {
      throw const DownloadCancelled();
    } on TimeoutException {
      throw DiscoverSourceException('${url.host} is not answering.');
    } on http.ClientException catch (error) {
      if (cancelToken?.isCancelled ?? false) throw const DownloadCancelled();
      final message = error.message.toLowerCase();
      if (message.contains('failed host lookup') ||
          message.contains('network is unreachable')) {
        throw const DiscoverOfflineException();
      }
      throw DiscoverSourceException('${url.host} could not be reached.');
    }
    if (response.statusCode >= 400) {
      await response.stream.drain<void>().catchError((_) {});
      throw DiscoverSourceException(
        response.statusCode == 503
            ? '${url.host} is temporarily unavailable.'
            : '${url.host} answered with an error (${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }
    final total = response.contentLength;
    if (total != null && total > maxBytes) {
      throw const DiscoverSourceException(
        'This file is too large to download.',
      );
    }
    final builder = BytesBuilder(copy: false);
    onProgress?.call(0, total);
    try {
      await for (final chunk in response.stream.timeout(stallTimeout)) {
        if (cancelToken?.isCancelled ?? false) throw const DownloadCancelled();
        builder.add(chunk);
        if (builder.length > maxBytes) {
          throw const DiscoverSourceException(
            'This file is too large to download.',
          );
        }
        onProgress?.call(builder.length, total);
      }
    } on http.RequestAbortedException {
      throw const DownloadCancelled();
    } on TimeoutException {
      throw const DiscoverSourceException('The download stalled.');
    } on http.ClientException {
      if (cancelToken?.isCancelled ?? false) throw const DownloadCancelled();
      throw const DiscoverSourceException('The download was interrupted.');
    }
    if (cancelToken?.isCancelled ?? false) throw const DownloadCancelled();
    if (total != null && builder.length < total) {
      throw const DiscoverSourceException('The download was interrupted.');
    }
    return builder.takeBytes();
  }

  /// Throws when [bytes] is not the expected kind of file, e.g. an error
  /// page served with status 200.
  static void validate(Uint8List bytes, BookFormat format) {
    final isZip = bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B;
    final head = String.fromCharCodes(bytes.take(1024));
    switch (format) {
      case BookFormat.epub when isZip:
      case BookFormat.pdf when head.contains('%PDF-'):
        return;
      default:
        if (head.trimLeft().startsWith('<')) {
          throw const DiscoverSourceException(
            'The library sent a web page instead of the book.',
          );
        }
        throw DiscoverSourceException(
          'The downloaded file is not a valid ${format.label}.',
        );
    }
  }
}
