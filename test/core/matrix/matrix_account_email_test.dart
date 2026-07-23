import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:orex_messenger/core/matrix/matrix_service.dart';

void main() {
  ThirdPartyIdentifier identifier(
    String address,
    ThirdPartyIdentifierMedium medium,
  ) =>
      ThirdPartyIdentifier(
        addedAt: 1,
        address: address,
        medium: medium,
        validatedAt: 1,
      );

  test('keeps only unique confirmed email identifiers', () {
    final emails = orexAccountEmailAddresses(<ThirdPartyIdentifier>[
      identifier(' User@Example.org ', ThirdPartyIdentifierMedium.email),
      identifier('user@example.org', ThirdPartyIdentifierMedium.email),
      identifier('+79990000000', ThirdPartyIdentifierMedium.msisdn),
      identifier('second@example.org', ThirdPartyIdentifierMedium.email),
    ]);

    expect(emails, <String>['second@example.org', 'User@Example.org']);
    expect(() => emails.add('third@example.org'), throwsUnsupportedError);
  });
}
