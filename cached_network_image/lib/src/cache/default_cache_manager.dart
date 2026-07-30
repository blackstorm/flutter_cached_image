import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:ui' as ui;

import 'package:cached_image_platform_interface/cached_image_platform_interface.dart';
import 'package:crypto/crypto.dart';
import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'cache_entry_metadata.dart';
import 'cache_metadata_store.dart';
import 'cleanup_strategy.dart';
import 'interceptors/cache_interceptor.dart';
import 'interceptors/http_interceptor.dart';
import 'interceptors/interceptor_runner.dart';
import 'shared_http_client.dart';

export 'cache_entry_metadata.dart';

const _kDefaultMaxAge = Duration(days: 30);
const _kDefaultMaxCacheObjects = 200;
const _kDefaultStalePeriod = Duration(days: 7);
const _kOrphanFileGracePeriod = Duration(minutes: 5);

const _supportedFileNames = ['jpg', 'jpeg', 'png', 'tga', 'cur', 'ico'];

/// Sanitizes a key so it doesn't exceed KV backends with short key limits.
String _sanitizeMetaKey(String key) {
  if (key.length <= 255) return key;
  final hash = sha256.convert(utf8.encode(key)).toString();
  // 255 max limit. 255 - 64 (sha256 hex length) - 1 (underscore) = 190
  return '${key.substring(0, 190)}_$hash';
}

/// Signature for a function that returns a cache base directory.
///
/// Defaults to [getTemporaryDirectory] when not specified.
typedef CacheDirectoryProvider = Future<io.Directory> Function();

/// Default cache manager: filesystem for image bytes + injected KV for metadata.
///
/// Does **not** bundle Hive/MMKV/sqflite. Host apps must pass [metadataStore].
class DefaultCacheManager extends CacheManager with ImageCacheManager {
  /// Creates a [DefaultCacheManager].
  ///
  /// [metadataStore] holds JSON-encoded [CacheEntryMetadata] entries.
  /// [stalePeriod] is how long a file remains valid in the cache.
  /// [maxNrOfCacheObjects] is the maximum before cleanup triggers.
  /// [httpClientFactory] allows injecting a custom HTTP client (useful for testing).
  /// [cacheDirectoryProvider] allows overriding where cache files are stored.
  ///   Defaults to [getTemporaryDirectory].
  DefaultCacheManager({
    required CacheMetadataStore metadataStore,
    this.stalePeriod = _kDefaultStalePeriod,
    this.maxNrOfCacheObjects = _kDefaultMaxCacheObjects,
    this.connectionParameters,
    http.Client Function()? httpClientFactory,
    CacheDirectoryProvider? cacheDirectoryProvider,
    List<HttpInterceptor> httpInterceptors = const [],
    List<CacheInterceptor> cacheInterceptors = const [],
    CleanupStrategy? cleanupStrategy,
  })  : _metadataStore = metadataStore,
        _httpClient = SharedHttpClient(httpClientFactory ?? http.Client.new),
        _cacheDirectoryProvider =
            cacheDirectoryProvider ?? getTemporaryDirectory,
        _httpInterceptors = httpInterceptors,
        _cacheInterceptors = cacheInterceptors,
        _cleanupStrategy = cleanupStrategy ?? const TtlCleanupStrategy();

  /// Duration before cached files are considered stale.
  final Duration stalePeriod;

  /// Maximum number of objects in the cache before cleanup.
  final int maxNrOfCacheObjects;

  /// Optional connection parameters for HTTP timeouts.
  ///
  /// When `null` (the default), no timeouts are applied and downloads may
  /// wait indefinitely — preserving the existing behaviour.
  final ConnectionParameters? connectionParameters;

  final SharedHttpClient _httpClient;

  /// Provider for the base cache directory.
  final CacheDirectoryProvider _cacheDirectoryProvider;

  /// Host-provided metadata KV store.
  final CacheMetadataStore _metadataStore;

  /// HTTP interceptors that run for every download.
  final List<HttpInterceptor> _httpInterceptors;

  /// Cache interceptors that run on hit, miss, and store events.
  final List<CacheInterceptor> _cacheInterceptors;

  /// Strategy that determines the eviction order when the cache is over capacity.
  final CleanupStrategy _cleanupStrategy;

  String? _cacheDir;
  bool _storeReady = false;

  /// Guards [_doInit] so that concurrent callers (e.g. multiple images
  /// loading at the same time on cold start) share the same init future.
  Completer<void>? _initCompleter;

  /// Handle to the background cleanup sweep launched by [_doInit], so
  /// [dispose] can wait for it instead of racing it.
  Future<void>? _cleanupFuture;

  /// Initialize the metadata store and cache directory.
  ///
  /// Uses a [Completer] to ensure that only one initialization runs at a
  /// time, even when multiple callers invoke this concurrently.
  Future<void> _ensureInitialized() {
    final currentCompleter = _initCompleter;
    if (currentCompleter != null) return currentCompleter.future;

    final completer = Completer<void>();
    _initCompleter = completer;

    _doInit().then((_) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }).catchError((Object e, StackTrace s) {
      // Allow retry on next call by clearing the completer that initiated
      // this initialization sequence.
      if (identical(_initCompleter, completer)) {
        _initCompleter = null;
      }
      if (!completer.isCompleted) {
        completer.completeError(e, s);
      }
    });

    return completer.future;
  }

  Future<void> _doInit() async {
    final dir = await _cacheDirectoryProvider();
    _cacheDir = path.join(dir.path, 'cached_network_image');
    await io.Directory(_cacheDir!).create(recursive: true);

    await _metadataStore.initialize();
    _storeReady = true;

    _cleanupFuture = _cleanupOldFiles();
    unawaited(_cleanupFuture);
  }

  CacheEntryMetadata? _readMeta(String logicalKey) {
    return _readMetaStoredKey(_sanitizeMetaKey(logicalKey));
  }

  CacheEntryMetadata? _readMetaStoredKey(String storedKey) {
    final raw = _metadataStore.getString(storedKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return CacheEntryMetadata.fromMap(decoded);
      }
    } on Object catch (e) {
      cacheLogger.log(
        'CacheManager: bad metadata for $storedKey: $e',
        CacheManagerLogLevel.warning,
      );
    }
    return null;
  }

  void _writeMeta(String logicalKey, CacheEntryMetadata metadata) {
    _metadataStore.putString(
      _sanitizeMetaKey(logicalKey),
      jsonEncode(metadata.toMap()),
    );
  }

  void _deleteMeta(String logicalKey) {
    _metadataStore.remove(_sanitizeMetaKey(logicalKey));
  }

  String _cacheFilePath(String relativePath) {
    return path.join(_cacheDir!, relativePath);
  }

  Future<void> _ensureCacheDirectoryExists() async {
    await io.Directory(_cacheDir!).create(recursive: true);
  }

  /// Builds a relative file path from key and extension.
  String _generateRelativePath(String key, String fileExtension) {
    final hash = key.hashCode.toUnsigned(32).toRadixString(16);
    return '$hash.$fileExtension';
  }

  /// Gets the file extension from a URL.
  String _getFileExtensionFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final pathSegment =
          uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
      if (pathSegment.contains('.')) {
        return pathSegment.split('.').last.toLowerCase();
      }
    } on Object catch (_) {
      // Ignore parse errors
    }
    return 'file';
  }

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) {
    final controller = StreamController<FileResponse>();
    _pushFileToStream(controller, url, key ?? url, headers, withProgress);
    return controller.stream;
  }

  Future<void> _pushFileToStream(
    StreamController<FileResponse> controller,
    String url,
    String key,
    Map<String, String>? headers,
    bool withProgress,
  ) async {
    await _ensureInitialized();

    FileInfo? cachedFile;
    try {
      cachedFile = await getFileFromCache(key);
      if (cachedFile != null) {
        final isExpired = cachedFile.validTill.isBefore(DateTime.now());
        final hitOutcome = await runOnHitChain(
          _cacheInterceptors,
          CacheHitData(fileInfo: cachedFile, key: key, isExpired: isExpired),
        );
        if (hitOutcome is CacheHitReturn) {
          cachedFile = hitOutcome.fileInfo;
          controller.add(cachedFile);
          withProgress = false;
        } else {
          // CacheHitRejected — treat as a miss, force re-download.
          // withProgress stays as-is so progress events fire during re-download.
          cachedFile = null;
        }
      }
    } on Object catch (e) {
      cacheLogger.log(
        'CacheManager: Failed to load cached file for $url with error:\n$e',
        CacheManagerLogLevel.debug,
      );
    }

    if (cachedFile == null || cachedFile.validTill.isBefore(DateTime.now())) {
      if (cachedFile == null) {
        // Run onMiss chain — interceptor may provide a synthetic response
        final syntheticFile = await runOnMissChain(
          _cacheInterceptors,
          CacheMissData(key: key, url: url),
        );
        if (syntheticFile != null) {
          controller.add(syntheticFile);
          await controller.close();
          return;
        }
      }
      try {
        await for (final response
            in _downloadFile(url, key, headers, withProgress)) {
          if (response is DownloadProgress && withProgress) {
            controller.add(response);
          }
          if (response is FileInfo) {
            controller.add(response);
          }
        }
      } on Object catch (e) {
        cacheLogger.log(
          'CacheManager: Failed to download file from $url with error:\n$e',
          CacheManagerLogLevel.debug,
        );
        if (cachedFile == null && controller.hasListener) {
          controller.addError(e);
        }
        if (cachedFile != null &&
            e is HttpExceptionWithStatus &&
            e.statusCode == 404) {
          if (controller.hasListener) {
            controller.addError(e);
          }
          await removeFile(key);
        }
      }
    }
    await controller.close();
  }

  Stream<FileResponse> _downloadFile(
    String url,
    String key,
    Map<String, String>? headers,
    bool withProgress,
  ) async* {
    cacheLogger.log(
      'CacheManager: Downloading $url',
      CacheManagerLogLevel.verbose,
    );

    // Splice 1: run onRequest chain — may mutate url/headers or short-circuit
    final reqData = HttpRequestData(
      url: url,
      headers: Map<String, String>.from(headers ?? {}),
    );
    final reqOutcome = await runOnRequestChain(_httpInterceptors, reqData);
    if (reqOutcome is HttpRequestResolved) {
      // An interceptor short-circuited: skip client.send() entirely
      yield* _processResponse(url, key, withProgress, reqOutcome.response);
      return;
    }

    final proceed = reqOutcome as HttpRequestProceed;
    SharedHttpClientResponse? clientResponse;
    http.StreamedResponse? rawResponse;
    try {
      clientResponse = await _httpClient.send(
        uri: Uri.parse(proceed.data.url),
        headers: proceed.data.headers,
        connectionTimeout: connectionParameters?.connectionTimeout,
      );
      final response = clientResponse.response;
      rawResponse = response;

      // Splice 2: run onResponse chain — interceptors may replace the response
      final processedRes = await runOnResponseChain(
        _httpInterceptors,
        HttpResponseData(response: response, originalUrl: url),
      );
      if (!identical(processedRes.response, response)) {
        await _cancelResponseStream(response);
        rawResponse = null;
      }
      if (processedRes.response.statusCode != 200 &&
          processedRes.response.statusCode != 202) {
        // _processResponse owns cancellation for invalid responses.
        rawResponse = null;
      }

      // _processResponse reads the stream; client must remain open until done
      yield* _processResponse(url, key, withProgress, processedRes);
    } catch (e, st) {
      final response = rawResponse;
      if (response != null) {
        await _cancelResponseStream(response);
      }

      // Splice 3: run onError chain for all errors (network, status, stream)
      final errorOutcome = await runOnErrorChain(_httpInterceptors, e, st);
      if (errorOutcome is HttpErrorResolved) {
        yield* _processResponse(url, key, withProgress, errorOutcome.response);
        return;
      }
      final rethrow_ = errorOutcome as HttpErrorRethrow;
      Error.throwWithStackTrace(rethrow_.error, rethrow_.stackTrace);
    } finally {
      clientResponse?.release();
    }
  }

  Future<void> _cancelResponseStream(http.StreamedResponse response) async {
    try {
      final subscription = response.stream.listen(
        null,
        onError: (Object _, StackTrace __) {},
      );
      await subscription.cancel();
    } on StateError catch (_) {
      // A downstream owner may already have consumed the single-subscription
      // stream. Other cleanup failures should remain visible.
    }
  }

  /// Processes an [HttpResponseData] into cached [FileResponse] events.
  ///
  /// Shared by the normal download path, onRequest-resolve short-circuit,
  /// and onError-resolve recovery path.
  Stream<FileResponse> _processResponse(
    String url,
    String key,
    bool withProgress,
    HttpResponseData resData,
  ) async* {
    final response = resData.response;

    if (response.statusCode != 200 && response.statusCode != 202) {
      await _cancelResponseStream(response);
      throw HttpExceptionWithStatus(
        response.statusCode,
        'Invalid statusCode: ${response.statusCode}',
        uri: Uri.parse(url),
      );
    }

    final contentLength = response.contentLength;
    final fileExtension = _getFileExtensionFromUrl(url);
    final relativePath = _generateRelativePath(key, fileExtension);
    final filePath = _cacheFilePath(relativePath);

    await _ensureCacheDirectoryExists();

    final tempFilePath =
        '$filePath.${DateTime.now().microsecondsSinceEpoch}.tmp';
    final tempFile = io.File(tempFilePath);
    final sink = tempFile.openWrite();

    final requestTimeout = connectionParameters?.requestTimeout;
    final stream = requestTimeout != null
        ? response.stream.timeout(requestTimeout)
        : response.stream;

    var receivedBytes = 0;
    var movedToFinalPath = false;
    try {
      await for (final chunk in stream) {
        receivedBytes += chunk.length;
        sink.add(chunk);
        if (withProgress) {
          yield DownloadProgress(url, contentLength, receivedBytes);
        }
      }
      await sink.flush();
      await sink.close();

      final finalFile = io.File(filePath);
      try {
        await tempFile.rename(filePath);
        movedToFinalPath = true;
      } on Object catch (_) {
        io.File? backupFile;
        try {
          if (await finalFile.exists()) {
            final backupPath =
                '$filePath.${DateTime.now().microsecondsSinceEpoch}.bak';
            backupFile = await finalFile.rename(backupPath);
          }

          await tempFile.rename(filePath);
          movedToFinalPath = true;
        } on Object catch (_) {
          if (backupFile != null && await backupFile.exists()) {
            if (await finalFile.exists()) {
              await finalFile.delete();
            }
            await backupFile.rename(filePath);
          }
          rethrow;
        }

        if (backupFile != null && await backupFile.exists()) {
          try {
            await backupFile.delete();
          } on Object catch (e) {
            cacheLogger.log(
              'CacheManager: Failed to delete backup file for $filePath with error:\n$e',
              CacheManagerLogLevel.warning,
            );
          }
        }
      }
    } on Object catch (_) {
      await sink.close();
      rethrow;
    } finally {
      if (!movedToFinalPath && await tempFile.exists()) {
        await tempFile.delete();
      }
    }

    // Store metadata in injected KV
    final validTill = DateTime.now().add(stalePeriod);
    final cacheHeaders = response.headers;
    final eTag = cacheHeaders['etag'];

    final metadata = CacheEntryMetadata(
      url: url,
      relativePath: relativePath,
      validTill: validTill,
      eTag: eTag,
      length: receivedBytes,
      touchedAt: DateTime.now(),
    );
    final storeOutcome = await runOnStoreChain(
      _cacheInterceptors,
      CacheStoreData(
        url: url,
        key: key,
        metadata: metadata,
        file: io.File(filePath),
      ),
    );
    final String deliveryPath;
    if (storeOutcome) {
      _writeMeta(key, metadata);
      deliveryPath = filePath;
    } else {
      // Interceptor rejected storage: copy to a temp file for this delivery,
      // then delete the cache-directory copy so nothing is orphaned there.
      final tempPath =
          '${io.Directory.systemTemp.path}/${path.basename(filePath)}'
          '.${DateTime.now().microsecondsSinceEpoch}.nocache';
      await io.File(filePath).copy(tempPath);
      final f = io.File(filePath);
      if (await f.exists()) await f.delete();
      deliveryPath = tempPath;
    }

    final localFile = const LocalFileSystem().file(deliveryPath);
    yield FileInfo(localFile, FileSource.Online, validTill, url);
  }

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async {
    await _ensureInitialized();

    final metadata = _readMeta(key);
    if (metadata == null) return null;

    final filePath = _cacheFilePath(metadata.relativePath);
    final file = io.File(filePath);
    if (!file.existsSync()) {
      // Metadata exists but file is missing, clean up
      _deleteMeta(key);
      return null;
    }

    final localFile = const LocalFileSystem().file(filePath);
    unawaited(_touchEntry(key));
    return FileInfo(
        localFile, FileSource.Cache, metadata.validTill, metadata.url);
  }

  /// Updates the [touchedAt] timestamp for [key] in the cache box.
  ///
  /// Re-reads the current entry immediately before writing so a concurrent
  /// update to other fields (e.g. a re-download) isn't clobbered by a touch
  /// based on stale metadata. Fire-and-forget — callers should wrap with
  /// [unawaited].
  Future<void> _touchEntry(String key) async {
    if (!_storeReady) return;
    try {
      final current = _readMeta(key);
      if (current == null) return;
      final updated = CacheEntryMetadata(
        url: current.url,
        relativePath: current.relativePath,
        validTill: current.validTill,
        eTag: current.eTag,
        length: current.length,
        touchedAt: DateTime.now(),
      );
      _writeMeta(key, updated);
    } on Object catch (e) {
      cacheLogger.log(
        'CacheManager: Failed to update touchedAt for $key: $e',
        CacheManagerLogLevel.debug,
      );
    }
  }

  @override
  Future<File> putFile(
    String url,
    List<int> fileBytes, {
    String? key,
    String? eTag,
    Duration maxAge = _kDefaultMaxAge,
    String fileExtension = 'file',
  }) async {
    await _ensureInitialized();

    key ??= url;
    final relativePath = _generateRelativePath(key, fileExtension);
    final filePath = _cacheFilePath(relativePath);

    await _ensureCacheDirectoryExists();

    final file = io.File(filePath);
    await file.writeAsBytes(fileBytes);

    final validTill = DateTime.now().add(maxAge);
    _writeMeta(
      key,
      CacheEntryMetadata(
        url: url,
        relativePath: relativePath,
        validTill: validTill,
        eTag: eTag,
        length: fileBytes.length,
        touchedAt: DateTime.now(),
      ),
    );

    return const LocalFileSystem().file(filePath);
  }

  @override
  Future<void> removeFile(String key) async {
    await _ensureInitialized();

    final metadata = _readMeta(key);
    if (metadata != null) {
      final file = io.File(_cacheFilePath(metadata.relativePath));
      if (await file.exists()) {
        await file.delete();
      }
      _deleteMeta(key);
    }
  }

  @override
  Future<void> emptyCache() async {
    await _ensureInitialized();

    // Delete all cached files
    for (final key in _metadataStore.keys.toList()) {
      final metadata = _readMetaStoredKey(key);
      if (metadata != null) {
        final file = io.File(_cacheFilePath(metadata.relativePath));
        if (await file.exists()) {
          await file.delete();
        }
      }
    }

    _metadataStore.clear();
  }

  @override
  Future<void> dispose() async {
    final inFlightInit = _initCompleter;
    if (inFlightInit != null) {
      try {
        await inFlightInit.future;
      } on Object catch (_) {
        // Ignore init errors during dispose.
      }
    }

    final inFlightCleanup = _cleanupFuture;
    if (inFlightCleanup != null) {
      try {
        await inFlightCleanup;
      } on Object catch (_) {
        // Already logged inside _cleanupOldFiles; ignore here.
      }
    }

    _httpClient.dispose();

    try {
      await _metadataStore.dispose();
    } on Object catch (_) {
      // Host store may already be closed.
    }

    _storeReady = false;
    _cacheDir = null;
    _initCompleter = null;
    _cleanupFuture = null;
  }

  /// Clean up files that haven't been used in a while.
  Future<void> _cleanupOldFiles() async {
    try {
      final now = DateTime.now();
      final entries = <MapEntry<String, CacheEntryMetadata>>[];

      for (final key in _metadataStore.keys.toList()) {
        final meta = _readMetaStoredKey(key);
        if (meta != null) {
          entries.add(MapEntry(key, meta));
        }
      }

      await _deleteOrphanedCacheFiles(
        entries.map((entry) => entry.value.relativePath).toSet(),
        now,
      );

      // Remove expired entries
      for (final entry in entries) {
        if (entry.value.validTill.isBefore(now)) {
          final file = io.File(_cacheFilePath(entry.value.relativePath));
          if (await file.exists()) {
            await file.delete();
          }
          _metadataStore.remove(entry.key);
        }
      }

      // If cache is still too large, remove oldest entries
      if (_metadataStore.length > maxNrOfCacheObjects) {
        final sortedEntries = _cleanupStrategy.sortForEviction(
          entries.where((e) => _metadataStore.containsKey(e.key)).toList(),
        );

        final toRemove = sortedEntries.length - maxNrOfCacheObjects;
        for (var i = 0; i < toRemove; i++) {
          final entry = sortedEntries[i];
          final file = io.File(_cacheFilePath(entry.value.relativePath));
          if (await file.exists()) {
            await file.delete();
          }
          _metadataStore.remove(entry.key);
        }
      }
    } on Object catch (e) {
      cacheLogger.log(
        'CacheManager: Error during cleanup: $e',
        CacheManagerLogLevel.warning,
      );
    }
  }

  Future<void> _deleteOrphanedCacheFiles(
    Set<String> knownRelativePaths,
    DateTime now,
  ) async {
    final cacheDir = io.Directory(_cacheDir!);
    if (!await cacheDir.exists()) return;

    await for (final entity in cacheDir.list()) {
      if (entity is! io.File) continue;

      final relativePath = path.relative(entity.path, from: _cacheDir!);
      if (knownRelativePaths.contains(relativePath)) continue;

      try {
        final stat = await entity.stat();
        if (now.difference(stat.modified) < _kOrphanFileGracePeriod) continue;
        await entity.delete();
      } on Object catch (e) {
        cacheLogger.log(
          'CacheManager: Error checking/deleting orphaned file '
          '${entity.path}: $e',
          CacheManagerLogLevel.warning,
        );
      }
    }
  }

  // ---- ImageCacheManager mixin implementation ----

  final Map<String, Stream<FileResponse>> _runningResizes = {};

  @override
  Stream<FileResponse> getImageFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
    int? maxHeight,
    int? maxWidth,
  }) async* {
    if (maxHeight == null && maxWidth == null) {
      yield* getFileStream(
        url,
        key: key,
        headers: headers,
        withProgress: withProgress,
      );
      return;
    }

    key ??= url;
    var resizedKey = 'resized';
    if (maxWidth != null) resizedKey += '_w$maxWidth';
    if (maxHeight != null) resizedKey += '_h$maxHeight';
    resizedKey += '_$key';

    final fromCache = await getFileFromCache(resizedKey);
    if (fromCache != null) {
      yield fromCache;
      if (fromCache.validTill.isAfter(DateTime.now())) {
        return;
      }
      withProgress = false;
    }

    var runningResize = _runningResizes[resizedKey];
    if (runningResize == null) {
      runningResize = _fetchedResizedFile(
        url,
        key,
        resizedKey,
        headers,
        withProgress,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      ).asBroadcastStream();
      _runningResizes[resizedKey] = runningResize;
    }
    yield* runningResize;
    _runningResizes.remove(resizedKey);
  }

  Stream<FileResponse> _fetchedResizedFile(
    String url,
    String originalKey,
    String resizedKey,
    Map<String, String>? headers,
    bool withProgress, {
    int? maxWidth,
    int? maxHeight,
  }) async* {
    await for (final response in getFileStream(
      url,
      key: originalKey,
      headers: headers,
      withProgress: withProgress,
    )) {
      if (response is DownloadProgress) {
        yield response;
      }
      if (response is FileInfo) {
        yield await _resizeImageFile(
          response,
          resizedKey,
          maxWidth,
          maxHeight,
        );
      }
    }
  }

  Future<FileInfo> _resizeImageFile(
    FileInfo originalFile,
    String key,
    int? maxWidth,
    int? maxHeight,
  ) async {
    final originalFileName = originalFile.file.path;
    final fileExtension = originalFileName.split('.').last;
    if (!_supportedFileNames.contains(fileExtension)) {
      return originalFile;
    }

    final image = await _decodeImage(originalFile.file);

    final shouldResize = (maxWidth != null && image.width > maxWidth) ||
        (maxHeight != null && image.height > maxHeight);
    if (!shouldResize) return originalFile;

    if (maxWidth != null && maxHeight != null) {
      final resizeFactorWidth = image.width / maxWidth;
      final resizeFactorHeight = image.height / maxHeight;
      final resizeFactor = max(resizeFactorHeight, resizeFactorWidth);
      maxWidth = (image.width / resizeFactor).round();
      maxHeight = (image.height / resizeFactor).round();
    }

    final resized = await _decodeImage(
      originalFile.file,
      width: maxWidth,
      height: maxHeight,
    );
    final resizedBytes =
        (await resized.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
    final maxAge = originalFile.validTill.difference(DateTime.now());

    final file = await putFile(
      originalFile.originalUrl,
      resizedBytes,
      key: key,
      maxAge: maxAge,
      fileExtension: fileExtension,
    );

    return FileInfo(
      file,
      originalFile.source,
      originalFile.validTill,
      originalFile.originalUrl,
    );
  }
}

Future<ui.Image> _decodeImage(
  File file, {
  int? width,
  int? height,
  bool allowUpscaling = false,
}) {
  final shouldResize = width != null || height != null;
  final fileImage = FileImage(file as io.File);
  final image = shouldResize
      ? ResizeImage(
          fileImage,
          width: width,
          height: height,
          allowUpscaling: allowUpscaling,
        )
      : fileImage as ImageProvider;
  final completer = Completer<ui.Image>();
  image.resolve(ImageConfiguration.empty).addListener(
    ImageStreamListener((info, _) {
      completer.complete(info.image);
      image.evict();
    }),
  );
  return completer.future;
}
