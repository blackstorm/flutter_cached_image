# flutter_cached_image

Fork of [cached_network_image_ce](https://pub.dev/packages/cached_network_image_ce) for MilkBaby / blackstorm apps.

## Design

- **Image bytes**: native filesystem (IO only; no web package).
- **Metadata**: **pluggable** [`CacheMetadataStore`](cached_network_image/lib/src/cache/cache_metadata_store.dart) — this package does **not** depend on Hive, MMKV, or sqflite.
- Host apps inject a store (e.g. MMKV in production, `MemoryCacheMetadataStore` in tests).

```dart
CachedNetworkImageProvider.defaultCacheManager = DefaultCacheManager(
  metadataStore: myCacheMetadataStore,
);
```

## Packages

| Path | Pub name |
|------|----------|
| `cached_network_image/` | `cached_network_image_ce` |
| `cached_network_image_platform_interface/` | `cached_network_image_platform_interface_ce` |

Branch: **main** (not upstream `develop`).
