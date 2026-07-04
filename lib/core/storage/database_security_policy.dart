import '../config/orex_config.dart';

final class OrexDatabaseSecurityPolicy {
  const OrexDatabaseSecurityPolicy._();

  static void validateDesktopCache({
    required OrexEnvironment environment,
    required bool encryptedAtRest,
    required bool allowInsecureDesktopCache,
    required String platformName,
  }) {
    if (encryptedAtRest) return;
    if (!environment.isProduction) return;
    if (allowInsecureDesktopCache) return;

    throw StateError(
      'Unencrypted Matrix cache is not allowed for production $platformName. '
      'Use a SQLCipher-backed desktop database or explicitly set '
      'OREX_ALLOW_INSECURE_DESKTOP_CACHE=true for non-public dogfooding builds.',
    );
  }
}
