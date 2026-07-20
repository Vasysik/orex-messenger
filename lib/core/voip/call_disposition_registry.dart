import 'dart:async';

import 'package:flutter/foundation.dart';

/// Owns short-lived call outcome state and replay tombstones.
///
/// Keeping these timers and maps outside VoipService makes the service an
/// orchestrator instead of the owner of every lifecycle detail.
final class OrexCallDispositionRegistry {
  OrexCallDispositionRegistry({this.maxExactAttempts = 256});

  final int maxExactAttempts;

  final Map<String, DateTime> _rejected = <String, DateTime>{};
  final Map<String, Timer> _rejectedTimers = <String, Timer>{};
  final Map<String, DateTime> _busy = <String, DateTime>{};
  final Map<String, Timer> _busyTimers = <String, Timer>{};
  final Map<String, DateTime> _legacy = <String, DateTime>{};
  final Map<String, Timer> _legacyTimers = <String, Timer>{};
  final Map<String, DateTime> _exact = <String, DateTime>{};
  final Map<String, Timer> _exactTimers = <String, Timer>{};

  DateTime? parseTimestamp(Object? raw) {
    final milliseconds = switch (raw) {
      int value => value,
      num value => value.toInt(),
      String value => int.tryParse(value),
      _ => null,
    };
    if (milliseconds == null || milliseconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(milliseconds);
  }

  void recordRejected(String roomId) => _recordRecent(
        roomId,
        values: _rejected,
        timers: _rejectedTimers,
      );

  bool wasRejected(String roomId) => _rejected.containsKey(roomId);

  void clearRejected(String roomId) => _clearRecent(
        roomId,
        values: _rejected,
        timers: _rejectedTimers,
      );

  void recordBusy(String roomId) => _recordRecent(
        roomId,
        values: _busy,
        timers: _busyTimers,
      );

  bool wasBusy(String roomId) => _busy.containsKey(roomId);

  void clearBusy(String roomId) => _clearRecent(
        roomId,
        values: _busy,
        timers: _busyTimers,
      );

  void _recordRecent(
    String roomId, {
    required Map<String, DateTime> values,
    required Map<String, Timer> timers,
  }) {
    values[roomId] = DateTime.now();
    timers.remove(roomId)?.cancel();
    timers[roomId] = Timer(const Duration(seconds: 60), () {
      timers.remove(roomId);
      values.remove(roomId);
    });
  }

  void _clearRecent(
    String roomId, {
    required Map<String, DateTime> values,
    required Map<String, Timer> timers,
  }) {
    timers.remove(roomId)?.cancel();
    values.remove(roomId);
  }

  void record(
    String roomId, {
    DateTime? occurredAt,
    String? ringEventId,
    Duration? cleanupAfter = const Duration(minutes: 2),
  }) {
    final timestamp = occurredAt ?? DateTime.now();
    if (ringEventId != null) {
      final key = _exactKey(roomId, ringEventId);
      _exact.remove(key);
      _exact[key] = timestamp;
      _exactTimers.remove(key)?.cancel();
      if (cleanupAfter != null) {
        _exactTimers[key] = Timer(cleanupAfter, () {
          _exactTimers.remove(key);
          _exact.remove(key);
        });
      }
      while (_exact.length > maxExactAttempts) {
        final oldest = _exact.keys.first;
        _exact.remove(oldest);
        _exactTimers.remove(oldest)?.cancel();
      }
      return;
    }

    final current = _legacy[roomId];
    if (current != null && !timestamp.isAfter(current)) return;
    _legacy[roomId] = timestamp;
    _legacyTimers.remove(roomId)?.cancel();
    if (cleanupAfter == null) return;
    _legacyTimers[roomId] = Timer(cleanupAfter, () {
      _legacyTimers.remove(roomId);
      if (_legacy[roomId] == timestamp) _legacy.remove(roomId);
    });
  }

  bool hasExact(String roomId, String ringEventId) =>
      _exact.containsKey(_exactKey(roomId, ringEventId));

  DateTime? legacyTimestamp(String roomId) => _legacy[roomId];

  bool hasLegacy(String roomId) => _legacy.containsKey(roomId);

  void clearLegacy(String roomId) {
    _legacyTimers.remove(roomId)?.cancel();
    _legacy.remove(roomId);
  }

  void promoteLegacy(
    String roomId,
    String ringEventId, {
    Duration? cleanupAfter = const Duration(minutes: 2),
  }) {
    final timestamp = _legacy[roomId];
    if (timestamp == null) return;
    clearLegacy(roomId);
    record(
      roomId,
      occurredAt: timestamp,
      ringEventId: ringEventId,
      cleanupAfter: cleanupAfter,
    );
  }

  void dispose() {
    for (final timer in <Timer>[
      ..._rejectedTimers.values,
      ..._busyTimers.values,
      ..._legacyTimers.values,
      ..._exactTimers.values,
    ]) {
      timer.cancel();
    }
    _rejectedTimers.clear();
    _busyTimers.clear();
    _legacyTimers.clear();
    _exactTimers.clear();
    _rejected.clear();
    _busy.clear();
    _legacy.clear();
    _exact.clear();
  }

  @visibleForTesting
  int get exactCount => _exact.length;

  static String _exactKey(String roomId, String ringEventId) =>
      '$roomId\u001f$ringEventId';
}
