import 'package:matrix/matrix.dart';

import '../logging/orex_logger.dart';
import 'call_attempt.dart';
import 'call_ring_targets.dart';
import 'matrix_call_control_transport.dart';
import 'matrix_request_gate.dart';

final class OrexCallSignalTypes {
  const OrexCallSignalTypes._();

  static const handled = 'com.orex.call.handled';
  static const accepted = 'com.orex.call.accepted';
  static const rejected = 'com.orex.call.rejected';
  static const busy = 'com.orex.call.busy';
  static const ended = 'com.orex.call.ended';
}

/// Matrix transport for one-to-one call attention/control events.
///
/// This class deliberately owns no call lifecycle state. VoipService decides
/// whether a signal is valid; this transport only resolves peers, builds a
/// privacy-minimal payload and sends it through the shared rate-limit gate.
final class PersonalCallSignaling {
  PersonalCallSignaling(
    this.client, {
    OrexMatrixRequestGate? requestGate,
  }) : _requestGate = requestGate ?? OrexMatrixRequestGate.shared {
    _controlTransport = MatrixCallControlTransport(
      client,
      requestGate: _requestGate,
    );
  }

  final Client client;
  final OrexMatrixRequestGate _requestGate;
  late final MatrixCallControlTransport _controlTransport;

  Future<void> sendDisposition(
    OrexCallInstance instance,
    String eventType,
  ) async {
    final room = client.getRoomById(instance.roomId);
    if (room == null) return;
    final peers = _peerTargets(room);
    if (peers.isEmpty) return;
    final content = <String, dynamic>{
      'room_id': instance.roomId,
      'call_id': instance.ringEventId ?? instance.roomId,
      'disposition_at_ms': DateTime.now().millisecondsSinceEpoch,
      if (instance.ringEventId != null)
        'orex_ring_event_id': instance.ringEventId,
    };
    await _controlTransport.send(
      room: room,
      userIds: peers,
      eventType: eventType,
      content: content,
      operationName: 'call-disposition:$eventType',
      coalesceKey: 'call-disposition:$eventType:${instance.routeKey}',
    );
  }

  Future<void> sendHandled(OrexCallInstance instance) async {
    final userId = client.userID?.trim();
    if (userId == null || userId.isEmpty) return;
    final content = <String, dynamic>{
      'room_id': instance.roomId,
      'call_id': instance.ringEventId ?? instance.roomId,
      'handled_at_ms': DateTime.now().millisecondsSinceEpoch,
      if (instance.ringEventId != null)
        'orex_ring_event_id': instance.ringEventId,
    };
    final deviceId = client.deviceID?.trim();
    if (deviceId != null && deviceId.isNotEmpty) {
      content['origin_device_id'] = deviceId;
    }
    final room = client.getRoomById(instance.roomId);
    if (room == null) return;
    await _controlTransport.send(
      room: room,
      userIds: {userId},
      eventType: OrexCallSignalTypes.handled,
      content: content,
      operationName: 'call-handled',
      coalesceKey: 'call-handled:${instance.routeKey}:${deviceId ?? 'unknown'}',
      excludeCurrentDevice: true,
      allowNoTargetDevices: true,
    );
  }

  Future<String?> sendRing(Room room, {required bool video}) async {
    final peers = _peerTargets(room);
    if (peers.isEmpty) return null;
    final notification = RtcNotificationContent.create(
      type: RtcNotificationType.ring,
      lifetime: const Duration(seconds: 45),
    );
    final transactionId = client.generateUniqueTransactionId();
    final content = <String, Object?>{
      ...notification.toJson(),
      'm.mentions': {'user_ids': peers.toList(growable: false)},
      'm.call.intent': video ? 'video' : 'audio',
    };
    try {
      return await _requestGate.run<String>(
        operationName: 'call-ring',
        coalesceKey: 'call-ring:${room.id}:${video ? 'video' : 'audio'}',
        operation: () => client.sendMessage(
          room.id,
          RtcNotificationContent.eventType,
          transactionId,
          content,
        ),
      );
    } catch (error) {
      OrexLog.d('Voip', 'RTC ring send failed room=${room.id}', error);
      rethrow;
    }
  }

  Future<bool> sendCancellation(
    Room room, {
    required String ringEventId,
    required String action,
  }) async {
    final peers = _peerTargets(room);
    if (peers.isEmpty) return false;
    final notification = RtcNotificationContent.create(
      type: RtcNotificationType.notification,
      lifetime: const Duration(seconds: 30),
    );
    final transactionId = client.generateUniqueTransactionId();
    final content = <String, Object?>{
      ...notification.toJson(),
      'm.mentions': {'user_ids': peers.toList(growable: false)},
      'orex_call_action': action,
      'orex_ring_event_id': ringEventId,
    };
    try {
      await _requestGate.run<void>(
        operationName: 'call-ring-cancel:$action',
        coalesceKey: 'call-ring-cancel:$action:${room.id}:$ringEventId',
        operation: () => client.sendMessage(
          room.id,
          RtcNotificationContent.eventType,
          transactionId,
          content,
        ),
      );
      return true;
    } catch (error) {
      OrexLog.d(
        'Voip',
        'RTC ring cancellation failed room=${room.id} action=$action',
        error,
      );
      return false;
    }
  }

  Set<String> _peerTargets(Room room) => orexResolveCallRingTargets(
        localUserId: client.userID,
        joinedUserIds: room
            .getParticipants([Membership.join])
            .map((user) => user.id),
        directChatMatrixId: room.directChatMatrixID,
      );
}
