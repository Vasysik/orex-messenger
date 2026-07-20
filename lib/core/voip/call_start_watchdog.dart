import 'dart:async';

final class OrexCallStageTimeout implements Exception {
  const OrexCallStageTimeout(this.stage, this.timeout);

  final String stage;
  final Duration timeout;

  @override
  String toString() =>
      'OrexCallStageTimeout(stage: $stage, timeout: ${timeout.inSeconds}s)';
}

Future<T> orexRunCallStage<T>({
  required String stage,
  required Duration timeout,
  required Future<T> Function() operation,
}) async {
  try {
    return await operation().timeout(timeout);
  } on TimeoutException {
    throw OrexCallStageTimeout(stage, timeout);
  }
}
