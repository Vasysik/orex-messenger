import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/features/home/home_notice_policy.dart';

void main() {
  group('shouldRecommendOrexKeyBackup', () {
    test('warns when key storage does not exist', () {
      expect(
        shouldRecommendOrexKeyBackup(
          encryptionEnabled: true,
          statusKnown: true,
          keyBackupEnabled: false,
          autoBackupEnabled: false,
        ),
        isTrue,
      );
    });

    test('warns when storage exists but automatic backup is off', () {
      expect(
        shouldRecommendOrexKeyBackup(
          encryptionEnabled: true,
          statusKnown: true,
          keyBackupEnabled: true,
          autoBackupEnabled: false,
        ),
        isTrue,
      );
    });

    test('does not warn while status is unknown or backup is fully enabled', () {
      expect(
        shouldRecommendOrexKeyBackup(
          encryptionEnabled: true,
          statusKnown: false,
          keyBackupEnabled: false,
          autoBackupEnabled: false,
        ),
        isFalse,
      );
      expect(
        shouldRecommendOrexKeyBackup(
          encryptionEnabled: true,
          statusKnown: true,
          keyBackupEnabled: true,
          autoBackupEnabled: true,
        ),
        isFalse,
      );
    });
  });

  OrexHomeNoticeKind? select({
    bool callIsBusy = false,
    bool needsVerification = false,
    bool updateAvailable = false,
    bool recommendKeyBackup = false,
    bool recommendAccountEmail = false,
  }) =>
      selectOrexHomeNotice(
        callIsBusy: callIsBusy,
        needsVerification: needsVerification,
        updateAvailable: updateAvailable,
        recommendKeyBackup: recommendKeyBackup,
        recommendAccountEmail: recommendAccountEmail,
      );

  test('shows only the highest-priority notice', () {
    expect(
      select(
        needsVerification: true,
        updateAvailable: true,
        recommendKeyBackup: true,
        recommendAccountEmail: true,
      ),
      OrexHomeNoticeKind.verification,
    );

    expect(
      select(
        updateAvailable: true,
        recommendKeyBackup: true,
        recommendAccountEmail: true,
      ),
      OrexHomeNoticeKind.update,
    );

    expect(
      select(
        recommendKeyBackup: true,
        recommendAccountEmail: true,
      ),
      OrexHomeNoticeKind.keyBackup,
    );
  });

  test('shows email recommendation after higher notices are gone', () {
    expect(
      select(recommendAccountEmail: true),
      OrexHomeNoticeKind.accountEmail,
    );
  });

  test('suppresses notices while a call is active', () {
    expect(
      select(
        callIsBusy: true,
        needsVerification: true,
        updateAvailable: true,
      ),
      isNull,
    );
  });
}
