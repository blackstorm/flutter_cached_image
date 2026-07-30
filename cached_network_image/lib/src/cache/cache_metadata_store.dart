/// Pluggable key-value store for cache **metadata only** (not image bytes).
///
/// This package does **not** depend on Hive, MMKV, or sqflite. Host apps inject
/// an implementation (e.g. MMKV in production, in-memory in tests).
///
/// Image bytes remain on the native filesystem under [DefaultCacheManager]'s
/// cache directory.
abstract interface class CacheMetadataStore {
  /// Prepare the store (open DB / mmap). Called once before other methods.
  Future<void> initialize();

  /// Read a UTF-8 string value, or `null` if missing.
  String? getString(String key);

  /// Write a UTF-8 string value.
  void putString(String key, String value);

  /// Remove one key.
  void remove(String key);

  /// Whether [key] exists.
  bool containsKey(String key);

  /// All keys currently stored (may include expired logical entries).
  List<String> get keys;

  /// Number of keys.
  int get length;

  /// Remove all keys.
  void clear();

  /// Release resources. Optional for in-memory stores.
  Future<void> dispose();
}

/// In-memory [CacheMetadataStore] for tests and ephemeral use.
final class MemoryCacheMetadataStore implements CacheMetadataStore {
  final Map<String, String> _data = <String, String>{};

  @override
  Future<void> initialize() async {}

  @override
  String? getString(String key) => _data[key];

  @override
  void putString(String key, String value) {
    _data[key] = value;
  }

  @override
  void remove(String key) {
    _data.remove(key);
  }

  @override
  bool containsKey(String key) => _data.containsKey(key);

  @override
  List<String> get keys => _data.keys.toList(growable: false);

  @override
  int get length => _data.length;

  @override
  void clear() => _data.clear();

  @override
  Future<void> dispose() async {
    _data.clear();
  }
}
