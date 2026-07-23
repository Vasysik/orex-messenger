import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/matrix/matrix_service.dart';

void main() {
  group('OrexQrLoginPayload', () {
    DateTime freshExpiry() => DateTime.fromMillisecondsSinceEpoch(
          DateTime.now()
              .toUtc()
              .add(const Duration(minutes: 2))
              .millisecondsSinceEpoch,
          isUtc: true,
        );

    test('parses a legacy direct login token', () {
      final expiresAt = freshExpiry();
      final encoded = OrexQrLoginPayload.loginToken(
        homeserver: Uri.parse('https://vasys.ru'),
        loginToken: 'one-time-token',
        expiresAt: expiresAt,
      ).encode();

      final parsed = OrexQrLoginPayload.parse(encoded);

      expect(parsed.isLoginToken, isTrue);
      expect(parsed.homeserver, Uri.parse('https://vasys.ru'));
      expect(parsed.loginToken, 'one-time-token');
      expect(parsed.expiresAt, expiresAt);
    });

    test('round-trips a rendezvous request', () {
      final secret = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final encoded = OrexQrLoginPayload.rendezvous(
        homeserver: Uri.parse('https://vasys.ru'),
        rendezvousUri: Uri.parse(
          'https://vasys.ru/_synapse/client/org.matrix.msc3886/rendezvous/session',
        ),
        secret: secret,
        challenge: 'challenge',
        expiresAt: freshExpiry(),
      ).encode();

      final parsed = OrexQrLoginPayload.parse(encoded);

      expect(parsed.isRendezvous, isTrue);
      expect(parsed.secret, orderedEquals(secret));
      expect(parsed.challenge, 'challenge');
      expect(
        parsed.rendezvousUri,
        Uri.parse(
          'https://vasys.ru/_synapse/client/org.matrix.msc3886/rendezvous/session',
        ),
      );
    });

    test('rejects an expired QR code', () {
      final encoded = OrexQrLoginPayload.loginToken(
        homeserver: Uri.parse('https://vasys.ru'),
        loginToken: 'expired-token',
        expiresAt: DateTime.utc(2020, 1, 1),
      ).encode();

      expect(
        () => OrexQrLoginPayload.parse(encoded),
        throwsA(
          isA<OrexAuthProtocolException>().having(
            (error) => error.code,
            'code',
            'OREX_QR_EXPIRED',
          ),
        ),
      );
    });
  });
}
