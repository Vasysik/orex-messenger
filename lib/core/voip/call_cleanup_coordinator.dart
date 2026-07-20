final class OrexCallCleanupSession {
  const OrexCallCleanupSession({
    required this.label,
    required this.leave,
    required this.disposeBackend,
  });

  final String label;
  final Future<void> Function() leave;
  final Future<void> Function() disposeBackend;
}

final class OrexCallCleanupFailure {
  const OrexCallCleanupFailure(this.step, this.error);

  final String step;
  final Object error;
}

final class OrexCallCleanupResult {
  const OrexCallCleanupResult({
    required this.membershipRemoved,
    required this.failures,
  });

  final bool membershipRemoved;
  final List<OrexCallCleanupFailure> failures;
}

/// Executes the ownership teardown contract in the only safe order:
/// local SDK sessions -> media-key backends -> Matrix membership.
final class OrexCallCleanupCoordinator {
  const OrexCallCleanupCoordinator();

  Future<OrexCallCleanupResult> cleanup({
    required Iterable<OrexCallCleanupSession> sessions,
    required Future<void> Function() removeMembership,
    Duration stepTimeout = const Duration(seconds: 10),
  }) async {
    final failures = <OrexCallCleanupFailure>[];
    for (final session in sessions) {
      try {
        await session.leave().timeout(stepTimeout);
      } catch (error) {
        failures.add(OrexCallCleanupFailure('${session.label}:leave', error));
      }
      try {
        await session.disposeBackend().timeout(stepTimeout);
      } catch (error) {
        failures.add(OrexCallCleanupFailure('${session.label}:backend', error));
      }
    }
    try {
      await removeMembership().timeout(stepTimeout);
      return OrexCallCleanupResult(
        membershipRemoved: true,
        failures: List<OrexCallCleanupFailure>.unmodifiable(failures),
      );
    } catch (error) {
      failures.add(OrexCallCleanupFailure('membership', error));
      return OrexCallCleanupResult(
        membershipRemoved: false,
        failures: List<OrexCallCleanupFailure>.unmodifiable(failures),
      );
    }
  }
}
