import 'package:matrix/matrix.dart';

import '../logging/orex_logger.dart';
import 'matrix_service.dart';
import 'orex_forwarded_content.dart';

const int orexForwardMaxEventsPerOperation = 100;
const int orexForwardMaxTargetsPerOperation = 20;

final class OrexForwardCancellation {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

final class OrexForwardProgress {
  const OrexForwardProgress({
    required this.completed,
    required this.total,
    required this.roomName,
  });

  final int completed;
  final int total;
  final String roomName;
}

final class OrexForwardFailure {
  const OrexForwardFailure({
    required this.roomName,
    required this.reason,
  });

  final String roomName;
  final String reason;
}

final class OrexForwardResult {
  const OrexForwardResult({
    required this.sentMessages,
    required this.completedRooms,
    required this.failures,
    required this.cancelled,
    this.fatalError,
  });

  final int sentMessages;
  final int completedRooms;
  final List<OrexForwardFailure> failures;
  final bool cancelled;
  final String? fatalError;

  bool get isSuccess => fatalError == null && !cancelled && failures.isEmpty;
}

/// Forwards existing Matrix messages without downloading/re-uploading media.
///
/// Only the small event content is copied. Existing `mxc://` references (and,
/// for encrypted media, their key descriptor) are placed into a new event that
/// Matrix encrypts for each destination room. Memory use therefore does not
/// grow with the attachment size.
final class OrexMessageForwarder {
  const OrexMessageForwarder(this.matrix);

  final MatrixService matrix;

  Future<OrexForwardResult> forward({
    required List<Event> events,
    required Timeline? timeline,
    required List<Room> targets,
    required OrexForwardCancellation cancellation,
    void Function(OrexForwardProgress progress)? onProgress,
  }) async {
    final uniqueEvents = <String, Event>{
      for (final event in events) event.eventId: event,
    }.values.toList()
      ..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));
    final uniqueTargets = <String, Room>{
      for (final room in targets) room.id: room,
    }.values.toList(growable: false);

    if (uniqueEvents.length > orexForwardMaxEventsPerOperation) {
      return const OrexForwardResult(
        sentMessages: 0,
        completedRooms: 0,
        failures: <OrexForwardFailure>[],
        cancelled: false,
        fatalError: 'За один раз можно переслать не больше 100 сообщений.',
      );
    }

    if (uniqueTargets.length > orexForwardMaxTargetsPerOperation) {
      return const OrexForwardResult(
        sentMessages: 0,
        completedRooms: 0,
        failures: <OrexForwardFailure>[],
        cancelled: false,
        fatalError: 'За один раз можно выбрать не больше 20 чатов.',
      );
    }

    final prepared = <Map<String, dynamic>>[];
    try {
      for (final event in uniqueEvents) {
        if (cancellation.isCancelled) {
          return const OrexForwardResult(
            sentMessages: 0,
            completedRooms: 0,
            failures: <OrexForwardFailure>[],
            cancelled: true,
          );
        }
        final display = timeline == null
            ? event
            : event.getDisplayEvent(timeline);
        prepared.add(
          orexBuildForwardedContent(
            Map<String, dynamic>.from(display.content),
          ),
        );
        if (prepared.length.isEven) {
          await Future<void>.delayed(Duration.zero);
        }
      }
    } on OrexForwardingException catch (error) {
      return OrexForwardResult(
        sentMessages: 0,
        completedRooms: 0,
        failures: const <OrexForwardFailure>[],
        cancelled: false,
        fatalError: error.message,
      );
    } catch (error, stackTrace) {
      OrexLog.d('Forward', 'prepare failed', error, stackTrace);
      return const OrexForwardResult(
        sentMessages: 0,
        completedRooms: 0,
        failures: <OrexForwardFailure>[],
        cancelled: false,
        fatalError: 'Не удалось подготовить сообщение к пересылке.',
      );
    }

    if (prepared.isEmpty || uniqueTargets.isEmpty) {
      return const OrexForwardResult(
        sentMessages: 0,
        completedRooms: 0,
        failures: <OrexForwardFailure>[],
        cancelled: false,
      );
    }

    var sentMessages = 0;
    var processed = 0;
    var completedRooms = 0;
    final failures = <OrexForwardFailure>[];
    final total = prepared.length * uniqueTargets.length;

    void report(String roomName) => onProgress?.call(
      OrexForwardProgress(
        completed: processed,
        total: total,
        roomName: roomName,
      ),
    );

    for (final room in uniqueTargets) {
      if (cancellation.isCancelled) break;
      final roomName = room.getLocalizedDisplayname();
      final roomProgressStart = processed;
      report(roomName);

      if (room.membership != Membership.join ||
          room.isSpace ||
          !matrix.canSendMessages(room)) {
        processed = roomProgressStart + prepared.length;
        failures.add(
          OrexForwardFailure(
            roomName: roomName,
            reason: 'Нет права отправлять сообщения в этот чат.',
          ),
        );
        report(roomName);
        continue;
      }

      if (room.encrypted &&
          prepared.any(orexForwardedContentNeedsMediaReEncryption)) {
        processed = roomProgressStart + prepared.length;
        failures.add(
          OrexForwardFailure(
            roomName: roomName,
            reason: 'Файл из открытого чата нельзя безопасно переслать '
                'в защищённый чат. Скачайте и отправьте его заново.',
          ),
        );
        report(roomName);
        continue;
      }

      var roomCompleted = true;
      try {
        await matrix.ensureCanSendToChannel(room);
        for (final content in prepared) {
          if (cancellation.isCancelled) {
            roomCompleted = false;
            break;
          }
          await room.sendEvent(Map<String, dynamic>.from(content));
          sentMessages++;
          processed++;
          report(roomName);
        }
      } catch (error, stackTrace) {
        roomCompleted = false;
        processed = roomProgressStart + prepared.length;
        failures.add(
          OrexForwardFailure(
            roomName: roomName,
            reason: 'Сервер не принял пересланное сообщение.',
          ),
        );
        report(roomName);
        OrexLog.d(
          'Forward',
          'send failed room=${room.id} sent=$sentMessages',
          error,
          stackTrace,
        );
      }
      if (roomCompleted) completedRooms++;
    }

    return OrexForwardResult(
      sentMessages: sentMessages,
      completedRooms: completedRooms,
      failures: List<OrexForwardFailure>.unmodifiable(failures),
      cancelled: cancellation.isCancelled,
    );
  }
}
