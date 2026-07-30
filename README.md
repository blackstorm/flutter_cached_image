# flutter_cached_image

Flutter network image cache with **pluggable metadata storage**.

## Packages

| Directory | Package name |
|-----------|----------------|
| `cached_network_image/` | **`cached_image`** |
| `cached_network_image_platform_interface/` | **`cached_image_platform_interface`** |

## Usage

```dart
import 'package:cached_image/cached_image.dart';

// Required: inject a CacheMetadataStore (e.g. MMKV in the host app).
CachedNetworkImageProvider.defaultCacheManager = DefaultCacheManager(
  metadataStore: myStore,
);

CachedNetworkImage(imageUrl: url);
```

Branch: **main**. IO-only (no web package). No bundled Hive/MMKV/sqflite.
