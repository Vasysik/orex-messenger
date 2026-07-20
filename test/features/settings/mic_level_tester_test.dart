import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/matrix/matrix_service.dart';
import 'package:orex_messenger/features/settings/mic_level_tester.dart';
import 'package:record/record.dart' as rec;

void main() {
  testWidgets('stopping during startStream releases the stale recorder', (
    tester,
  ) async {
    final recorders = <_DeferredRecorder>[];
    await tester.pumpWidget(_tester(recorders, inputDeviceId: 'mic-a'));
    await _beginStart(tester, recorders);
    final recorder = recorders.single;

    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    recorder.completeStart();
    await _pumpUntil(tester, () => recorder.disposeCalls == 1);

    expect(recorder.stopCalls, 1);
  });

  testWidgets('disposing during startStream releases the stale recorder', (
    tester,
  ) async {
    final recorders = <_DeferredRecorder>[];
    await tester.pumpWidget(_tester(recorders, inputDeviceId: 'mic-a'));
    await _beginStart(tester, recorders);
    final recorder = recorders.single;

    await tester.pumpWidget(const SizedBox.shrink());
    recorder.completeStart();
    await _pumpUntil(tester, () => recorder.disposeCalls == 1);

    expect(recorder.stopCalls, 1);
  });

  testWidgets('device change waits for stale recorder cleanup before restart', (
    tester,
  ) async {
    final recorders = <_DeferredRecorder>[];
    await tester.pumpWidget(_tester(recorders, inputDeviceId: 'mic-a'));
    await _beginStart(tester, recorders);
    final first = recorders.single;

    await tester.pumpWidget(_tester(recorders, inputDeviceId: 'mic-b'));
    await tester.pump();
    expect(recorders, hasLength(1));

    first.completeStart();
    await _pumpUntil(tester, () => recorders.length == 2);
    expect(first.disposeCalls, 1);

    final second = recorders.last;
    second.completeStart();
    await tester.pump();
    await tester.pump();
  });
}

Future<void> _beginStart(
  WidgetTester tester,
  List<_DeferredRecorder> recorders,
) async {
  await tester.tap(find.byType(FilledButton));
  await _pumpUntil(tester, () => recorders.isNotEmpty);
  await _pumpUntil(tester, () => recorders.single.startRequested.isCompleted);
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() completed) async {
  for (var index = 0; index < 20 && !completed(); index++) {
    await tester.pump();
    await Future<void>.value();
  }
  expect(completed(), isTrue);
}

Widget _tester(
  List<_DeferredRecorder> recorders, {
  required String inputDeviceId,
}) {
  return MaterialApp(
    home: Scaffold(
      body: OrexMicLevelTester(
        key: const ValueKey('mic-level-tester'),
        matrix: _FakeMatrixService(),
        inputDeviceId: inputDeviceId,
        thresholdDb: -35,
        thresholdEnabled: true,
        onThresholdChanged: (_) {},
        onThresholdEnabledChanged: (_) {},
        recorderFactory: () {
          final recorder = _DeferredRecorder();
          recorders.add(recorder);
          return recorder;
        },
      ),
    ),
  );
}

class _FakeMatrixService extends Fake implements MatrixService {}

class _DeferredRecorder implements OrexMicLevelRecorder {
  final startRequested = Completer<void>();
  final _start = Completer<Stream<Uint8List>>();
  var stopCalls = 0;
  var disposeCalls = 0;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<rec.InputDevice?> resolveInputDevice(String? inputDeviceId) async =>
      null;

  @override
  Future<Stream<Uint8List>> startStream(rec.RecordConfig config) {
    startRequested.complete();
    return _start.future;
  }

  void completeStart() {
    _start.complete(const Stream<Uint8List>.empty());
  }

  @override
  Stream<rec.Amplitude> onAmplitudeChanged(Duration interval) =>
      const Stream<rec.Amplitude>.empty();

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}
