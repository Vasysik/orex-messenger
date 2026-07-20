import 'package:matrix/matrix.dart';

import '../config/orex_config.dart';
import 'matrix_request_gate.dart';

/// Sends call-control payloads to concrete Matrix devices.
///
/// Encrypted rooms use Olm-encrypted to-device events, so the homeserver cannot
/// read the control payload. Authenticity still follows Matrix device trust: the
/// server can delay/drop/replay traffic and can influence the device list seen by
/// an unverified client. Exact attempt identity and timestamp policy constrain
/// replay. The unencrypted branch exists only for the explicit
/// `OREX_ALLOW_UNENCRYPTED_CALLS` compatibility mode.
final class MatrixCallControlTransport {
  MatrixCallControlTransport(
    this.client, {
    OrexMatrixRequestGate? requestGate,
  }) : _requestGate = requestGate ?? OrexMatrixRequestGate.shared;

  final Client client;
  final OrexMatrixRequestGate _requestGate;

  Future<void> send({
    required Room room,
    required Set<String> userIds,
    required String eventType,
    required Map<String, dynamic> content,
    required String operationName,
    required String coalesceKey,
    bool excludeCurrentDevice = false,
    bool allowNoTargetDevices = false,
  }) async {
    if (userIds.isEmpty) return;
    if (!room.encrypted) {
      if (!OrexConfig.allowUnencryptedCalls) {
        throw StateError('Plaintext call control is disabled');
      }
      final transactionId = client.generateUniqueTransactionId();
      final payload = <String, Map<String, Map<String, dynamic>>>{
        for (final userId in userIds)
          userId: {'*': content},
      };
      await _requestGate.run<void>(
        operationName: operationName,
        coalesceKey: coalesceKey,
        operation: () => client.sendToDevice(
          eventType,
          transactionId,
          payload,
        ),
      );
      return;
    }

    final devices = await _resolveEncryptedTargets(
      userIds,
      excludeCurrentDevice: excludeCurrentDevice,
    );
    if (devices.isEmpty) {
      if (allowNoTargetDevices) return;
      throw StateError(
        'No trusted Matrix device keys for encrypted call control',
      );
    }
    await _requestGate.run<void>(
      operationName: operationName,
      coalesceKey: coalesceKey,
      operation: () => client.sendToDeviceEncrypted(
        devices,
        eventType,
        content,
      ),
    );
  }

  Future<List<DeviceKeys>> _resolveEncryptedTargets(
    Set<String> userIds, {
    required bool excludeCurrentDevice,
  }) async {
    if (!client.encryptionEnabled || client.encryption == null) {
      throw StateError('Matrix encryption is unavailable for call control');
    }
    await client.userDeviceKeysLoading;
    var missingUsers = userIds
        .where(
          (userId) =>
              client.userDeviceKeys[userId]?.deviceKeys.isNotEmpty != true,
        )
        .toSet();
    if (missingUsers.isNotEmpty) {
      await client.updateUserDeviceKeys(additionalUsers: missingUsers);
      missingUsers = userIds
          .where(
            (userId) =>
                client.userDeviceKeys[userId]?.deviceKeys.isNotEmpty != true,
          )
          .toSet();
    }
    if (missingUsers.isNotEmpty) {
      throw StateError(
        'Missing Matrix DeviceKeys for ${missingUsers.join(', ')}',
      );
    }

    final currentUserId = client.userID;
    final currentDeviceId = client.deviceID;
    final devices = <DeviceKeys>[];
    for (final userId in userIds) {
      final userDevices = client.userDeviceKeys[userId]?.deviceKeys.values;
      if (userDevices == null) continue;
      for (final device in userDevices) {
        if (device.blocked) continue;
        if (excludeCurrentDevice &&
            userId == currentUserId &&
            device.deviceId == currentDeviceId) {
          continue;
        }
        devices.add(device);
      }
    }
    return devices;
  }
}
