import 'dart:convert';

class OrexUpdateFormatException implements Exception {
  const OrexUpdateFormatException(this.message);

  final String message;

  @override
  String toString() => 'OrexUpdateFormatException: $message';
}

class OrexUpdateArtifact {
  const OrexUpdateArtifact({
    required this.key,
    required this.uri,
    this.sizeBytes,
  });

  final String key;
  final Uri uri;
  final int? sizeBytes;
}

class OrexUpdateRelease {
  const OrexUpdateRelease({
    required this.version,
    required this.build,
    required this.artifacts,
    this.notesUri,
    this.notes,
  });

  final String version;
  final int build;
  final Map<String, OrexUpdateArtifact> artifacts;
  final Uri? notesUri;
  final String? notes;

  String get label => '$version+$build';
  String get displayLabel => '$version · Сборка $build';

  OrexUpdateArtifact? artifactFor(String key) => artifacts[key];

  OrexUpdateRelease copyWithNotes(String? value) => OrexUpdateRelease(
    version: version,
    build: build,
    artifacts: artifacts,
    notesUri: notesUri,
    notes: value,
  );

  static OrexUpdateRelease parse(
    String body, {
    required Uri feedUri,
    required Uri updateBaseUri,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const OrexUpdateFormatException('latest.json is not valid JSON');
    }
    if (decoded is! Map<String, Object?>) {
      throw const OrexUpdateFormatException('latest.json must be an object');
    }

    final version = decoded['version'];
    final build = decoded['build'];
    if (version is! String || !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
      throw const OrexUpdateFormatException(
        'version must use the numeric x.y.z format',
      );
    }
    if (build is! int || build <= 0) {
      throw const OrexUpdateFormatException('build must be a positive integer');
    }

    final rawArtifacts = decoded['artifacts'];
    if (rawArtifacts is! Map<String, Object?>) {
      throw const OrexUpdateFormatException('artifacts must be an object');
    }

    final releaseDirectory = feedUri.resolve('$version+$build/');
    final artifacts = <String, OrexUpdateArtifact>{};
    for (final entry in rawArtifacts.entries) {
      final key = entry.key;
      final raw = entry.value;
      if (raw is! Map<String, Object?>) continue;
      final rawUrl = raw['url'];
      if (rawUrl is! String || rawUrl.trim().isEmpty) continue;
      final uri = _resolveTrustedUri(
        rawUrl,
        feedUri: feedUri,
        updateBaseUri: updateBaseUri,
        field: 'artifacts.$key.url',
      );
      final expectedFilename = _expectedFilename(key, version, build);
      if (expectedFilename == null) continue;
      if (!_isInsideDirectory(uri, releaseDirectory) ||
          uri.pathSegments.isEmpty ||
          uri.pathSegments.last != expectedFilename) {
        throw OrexUpdateFormatException(
          'artifacts.$key.url must point to $version+$build/$expectedFilename',
        );
      }
      final rawSize = raw['size_bytes'];
      final size = rawSize is int && rawSize > 0 ? rawSize : null;
      artifacts[key] = OrexUpdateArtifact(key: key, uri: uri, sizeBytes: size);
    }
    if (artifacts.isEmpty) {
      throw const OrexUpdateFormatException(
        'latest.json does not contain supported artifacts',
      );
    }

    Uri? notesUri;
    final rawNotesUrl = decoded['notes_url'];
    if (rawNotesUrl is String && rawNotesUrl.trim().isNotEmpty) {
      notesUri = _resolveTrustedUri(
        rawNotesUrl,
        feedUri: feedUri,
        updateBaseUri: updateBaseUri,
        field: 'notes_url',
      );
      if (!_isInsideDirectory(notesUri, releaseDirectory) ||
          notesUri.pathSegments.isEmpty ||
          notesUri.pathSegments.last != 'notes.md') {
        throw OrexUpdateFormatException(
          'notes_url must point to $version+$build/notes.md',
        );
      }
    }

    return OrexUpdateRelease(
      version: version,
      build: build,
      artifacts: Map.unmodifiable(artifacts),
      notesUri: notesUri,
    );
  }

  static String? _expectedFilename(String key, String version, int build) {
    final release = '$version+$build';
    return switch (key) {
      'windows-x64' => 'Orex-Setup-$release.exe',
      'android-arm64-v8a' => 'app-arm64-v8a-$release.apk',
      'android-armeabi-v7a' => 'app-armeabi-v7a-$release.apk',
      _ => null,
    };
  }

  static Uri _resolveTrustedUri(
    String raw, {
    required Uri feedUri,
    required Uri updateBaseUri,
    required String field,
  }) {
    final uri = feedUri.resolve(raw.trim());
    final normalizedBase = _withTrailingSlash(updateBaseUri);
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !_isInsideDirectory(uri, normalizedBase)) {
      throw OrexUpdateFormatException(
        '$field must stay inside ${normalizedBase.origin}${normalizedBase.path}',
      );
    }
    return uri;
  }

  static bool _isInsideDirectory(Uri uri, Uri directory) {
    final normalized = _withTrailingSlash(directory);
    return uri.scheme == normalized.scheme &&
        uri.host == normalized.host &&
        uri.port == normalized.port &&
        _trustedPath(uri.path).startsWith(_trustedPath(normalized.path));
  }

  /// Keeps a release directory written with `%2B` equivalent to one written
  /// with a literal `+`, while leaving every other escaped path character
  /// encoded for the trust-boundary comparison.
  static String _trustedPath(String path) =>
      path.replaceAll(RegExp(r'%2[bB]'), '+');

  static Uri _withTrailingSlash(Uri uri) {
    final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
    return uri.replace(path: path, query: null, fragment: null);
  }
}
