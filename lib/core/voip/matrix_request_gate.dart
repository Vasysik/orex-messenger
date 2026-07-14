import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;

import '../logging/orex_logger.dart';

typedef OrexMatrixOperation<T> = Future<T> Function();

@immutable
final class OrexMatrixRateLimitInfo {
  const OrexMatrixRateLimitInfo({
    required this.isRateLimited,
    this.retryAfter,
  });

  final bool isRateLimited;
  final Duration? retryAfter;
}

/// Extracts Matrix `M_LIMIT_EXCEEDED` metadata without depending on one SDK
/// exception shape. Matrix SDK majors have exposed `retry_after_ms` under
/// different field names, while proxies sometimes retain it only in text.
OrexMatrixRateLimitInfo orexMatrixRateLimitInfo(Object error) {
  int? retryAfterMs;
  final dynamic dynamicError = error;
  try {
    final value = dynamicError.retryAfterMs;
    if (value is num) retryAfterMs = value.toInt();
  } catch (_) {}
  try {
    final value = dynamicError.retry_after_ms;
    if (retryAfterMs == null && value is num) retryAfterMs = value.toInt();
  } catch (_) {}
  try {
    final value = dynamicError.retryAfter;
    if (retryAfterMs == null && value is Duration) {
      retryAfterMs = value.inMilliseconds;
    } else if (retryAfterMs == null && value is num) {
      retryAfterMs = value.toInt();
    }
  } catch (_) {}

  String? errcode;
  try {
    final value = dynamicError.errcode;
    if (value != null) errcode = value.toString();
  } catch (_) {}
  if (error is Map) {
    final value = error['errcode'];
    if (value != null) errcode ??= value.toString();
    final retry = error['retry_after_ms'];
    if (retryAfterMs == null && retry is num) retryAfterMs = retry.toInt();
  }

  final text = error.toString();
  final normalized = '${errcode ?? ''} $text'.toUpperCase();
  final isRateLimited = normalized.contains('M_LIMIT_EXCEEDED') ||
      normalized.contains('TOO MANY REQUESTS') ||
      normalized.contains('HTTP 429') ||
      normalized.contains('STATUSCODE: 429');
  retryAfterMs ??= _retryAfterFromText(text);
  return OrexMatrixRateLimitInfo(
    isRateLimited: isRateLimited,
    retryAfter: retryAfterMs == null || retryAfterMs <= 0
        ? null
        : Duration(milliseconds: retryAfterMs),
  );
}

bool orexIsMatrixRateLimitError(Object error) =>
    orexMatrixRateLimitInfo(error).isRateLimited;

int? _retryAfterFromText(String text) {
  final match = RegExp(
    r'(?:retry[_ ]?after(?:[_ ]?ms)?)[^0-9]{0,16}([0-9]{1,9})',
    caseSensitive: false,
  ).firstMatch(text);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// One process-wide gate for Matrix writes used by calls.
///
/// It provides three guarantees:
/// 1. call-control writes are serialized instead of bursting concurrently;
/// 2. duplicate in-flight writes with the same semantic key are coalesced;
/// 3. a server-provided `retry_after_ms` blocks later writes too, preventing a
///    retry storm across ring, membership cleanup and media-key messages.
final class OrexMatrixRequestGate {
  OrexMatrixRequestGate({
    this.minimumSpacing = const Duration(milliseconds: 90),
    this.maximumRetryDelay = const Duration(minutes: 2),
    this.defaultOperationTimeout = const Duration(seconds: 15),
  });

  static final OrexMatrixRequestGate shared = OrexMatrixRequestGate();

  final Duration minimumSpacing;
  final Duration maximumRetryDelay;
  final Duration defaultOperationTimeout;

  Future<void> _tail = Future<void>.value();
  final Map<String, Future<Object?>> _inFlight = <String, Future<Object?>>{};
  DateTime? _blockedUntil;
  DateTime? _lastStartedAt;

  Future<T> run<T>({
    required String operationName,
    required OrexMatrixOperation<T> operation,
    String? coalesceKey,
    int maxAttempts = 3,
    Duration? operationTimeout,
  }) {
    if (maxAttempts < 1) {
      throw ArgumentError.value(maxAttempts, 'maxAttempts', 'must be >= 1');
    }
    final key = coalesceKey?.trim();
    if (key != null && key.isNotEmpty) {
      final existing = _inFlight[key];
      if (existing != null) return existing.then((value) => value as T);
    }

    final queued = _tail.then<T>((_) async {
      Object? lastError;
      StackTrace? lastStack;
      for (var attempt = 0; attempt < maxAttempts; attempt++) {
        await _waitBeforeNextRequest();
        _lastStartedAt = DateTime.now();
        try {
          final pending = operation();
          return await pending.timeout(
            operationTimeout ?? defaultOperationTimeout,
          );
        } catch (error, stack) {
          lastError = error;
          lastStack = stack;
          final rateLimit = orexMatrixRateLimitInfo(error);
          if (rateLimit.isRateLimited) {
            final retryDelay = _boundedDelay(
              rateLimit.retryAfter ?? _fallbackDelay(attempt),
            );
            _extendGlobalBlock(retryDelay);
            OrexLog.d(
              'Voip',
              'Matrix write rate-limited operation=$operationName '
                  'attempt=${attempt + 1}/$maxAttempts '
                  'retry=${retryDelay.inMilliseconds}ms',
            );
          } else {
            // Unknown failures are not safe to replay: membership and control
            // writes may already have reached the homeserver before a transport
            // error surfaced locally. Retry only explicit Matrix 429 responses.
            Error.throwWithStackTrace(error, stack);
          }
          if (attempt + 1 >= maxAttempts) {
            Error.throwWithStackTrace(error, stack);
          }
        }
      }
      Error.throwWithStackTrace(
        lastError ?? StateError('$operationName failed'),
        lastStack ?? StackTrace.current,
      );
    });

    final asObject = queued.then<Object?>((value) => value);
    _tail = asObject.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    if (key != null && key.isNotEmpty) {
      _inFlight[key] = asObject;
      void cleanup() {
        if (identical(_inFlight[key], asObject)) _inFlight.remove(key);
      }
      unawaited(
        asObject.then<void>(
          (_) => cleanup(),
          onError: (Object _, StackTrace _) => cleanup(),
        ),
      );
    }
    return queued;
  }

  Future<void> _waitBeforeNextRequest() async {
    final now = DateTime.now();
    var wait = Duration.zero;
    final blockedUntil = _blockedUntil;
    if (blockedUntil != null && blockedUntil.isAfter(now)) {
      wait = blockedUntil.difference(now);
    }
    final lastStartedAt = _lastStartedAt;
    if (lastStartedAt != null) {
      final spacingUntil = lastStartedAt.add(minimumSpacing);
      if (spacingUntil.isAfter(now)) {
        final spacing = spacingUntil.difference(now);
        if (spacing > wait) wait = spacing;
      }
    }
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  void _extendGlobalBlock(Duration delay) {
    final candidate = DateTime.now().add(_boundedDelay(delay));
    final current = _blockedUntil;
    if (current == null || candidate.isAfter(current)) _blockedUntil = candidate;
  }

  Duration _fallbackDelay(int attempt) {
    final boundedAttempt = attempt < 0 ? 0 : (attempt > 5 ? 5 : attempt);
    final multiplier = 1 << boundedAttempt;
    return _boundedDelay(Duration(milliseconds: 650 * multiplier));
  }

  Duration _boundedDelay(Duration value) {
    if (value.isNegative) return Duration.zero;
    return value > maximumRetryDelay ? maximumRetryDelay : value;
  }
}
