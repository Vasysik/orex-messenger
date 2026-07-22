import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/features/home/home_notice_policy.dart';

void main() {
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
