import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/push/push_registration_service.dart';

void main() {
  const config = OrexPushRegistrationConfig(
    gateway: Uri.parse('https://push.example.org/_matrix/push/v1/notify'),
    appId: 'ru.orex.messenger.android',
    appDisplayName: 'Orex Messenger',
    deviceDisplayName: 'Orex Android · DEVICE',
    language: 'ru-RU',
    platform: 'android',
  );

  test('registers current token and persists it for the account', () async {
    final registrar = _FakeRegistrar();
    final store = _MemoryTokenStore();
    final changes = StreamController<String>.broadcast();
    final service = OrexPushRegistrationService(
      registrar: registrar,
      tokenStore: store,
      currentToken: () async => 'token-a',
      tokenChanges: changes.stream,
      accountKey: () => '@user:example.org|DEVICE',
      appId: config.appId,
      config: () => config,
    );

    await service.start();
    await service.sync();

    expect(registrar.calls, ['register:token-a']);
    expect(await store.read('@user:example.org|DEVICE'), 'token-a');

    await service.dispose();
    await changes.close();
  });

  test('deletes stale pushkey before registering a rotated token', () async {
    final registrar = _FakeRegistrar();
    final store = _MemoryTokenStore()
      ..values['@user:example.org|DEVICE'] = 'token-old';
    final changes = StreamController<String>.broadcast();
    final service = OrexPushRegistrationService(
      registrar: registrar,
      tokenStore: store,
      currentToken: () async => 'token-new',
      tokenChanges: changes.stream,
      accountKey: () => '@user:example.org|DEVICE',
      appId: config.appId,
      config: () => config,
    );

    await service.start();
    await service.sync();

    expect(registrar.calls, [
      'unregister:token-old',
      'register:token-new',
    ]);
    expect(await store.read('@user:example.org|DEVICE'), 'token-new');

    await service.dispose();
    await changes.close();
  });

  test('token refresh is serialized behind an in-flight registration', () async {
    final firstRegister = Completer<void>();
    final registrar = _FakeRegistrar(onFirstRegister: firstRegister.future);
    final store = _MemoryTokenStore();
    final changes = StreamController<String>.broadcast();
    var token = 'token-a';
    final service = OrexPushRegistrationService(
      registrar: registrar,
      tokenStore: store,
      currentToken: () async => token,
      tokenChanges: changes.stream,
      accountKey: () => '@user:example.org|DEVICE',
      appId: config.appId,
      config: () => config,
    );

    await service.start();
    final firstSync = service.sync();
    await registrar.firstRegisterStarted.future;

    token = 'token-b';
    changes.add(token);
    await Future<void>.delayed(Duration.zero);
    expect(registrar.calls, ['register:token-a']);

    firstRegister.complete();
    await firstSync;
    await service.sync(token: token);

    expect(registrar.calls, [
      'register:token-a',
      'unregister:token-a',
      'register:token-b',
      'register:token-b',
    ]);

    await service.dispose();
    await changes.close();
  });

  test('token refresh cannot re-register a pusher during logout', () async {
    final registrar = _FakeRegistrar();
    final store = _MemoryTokenStore();
    final changes = StreamController<String>.broadcast();
    var token = 'token-a';
    final service = OrexPushRegistrationService(
      registrar: registrar,
      tokenStore: store,
      currentToken: () async => token,
      tokenChanges: changes.stream,
      accountKey: () => '@user:example.org|DEVICE',
      appId: config.appId,
      config: () => config,
    );

    await service.start();
    await service.sync();
    await service.unregisterBeforeLogout();

    token = 'token-b';
    changes.add(token);
    await Future<void>.delayed(Duration.zero);
    await service.sync(token: token);

    expect(registrar.calls, [
      'register:token-a',
      'unregister:token-a',
    ]);

    service.resume();
    await service.sync(token: token);
    expect(registrar.calls.last, 'register:token-b');

    await service.dispose();
    await changes.close();
  });

  test('failed logout cleanup resumes registration for the active session', () async {
    final registrar = _FakeRegistrar(throwOnUnregister: true);
    final store = _MemoryTokenStore()
      ..values['@user:example.org|DEVICE'] = 'token-old';
    final changes = StreamController<String>.broadcast();
    final service = OrexPushRegistrationService(
      registrar: registrar,
      tokenStore: store,
      currentToken: () async => null,
      tokenChanges: changes.stream,
      accountKey: () => '@user:example.org|DEVICE',
      appId: config.appId,
      config: () => config,
    );

    await service.start();
    await expectLater(service.unregisterBeforeLogout(), throwsStateError);

    registrar.throwOnUnregister = false;
    await service.sync(token: 'token-new');
    expect(registrar.calls.last, 'register:token-new');

    await service.dispose();
    await changes.close();
  });

  test('logout removes a stored pusher even when registration is disabled', () async {
    final registrar = _FakeRegistrar();
    final store = _MemoryTokenStore()
      ..values['@user:example.org|DEVICE'] = 'token-old';
    final changes = StreamController<String>.broadcast();
    final service = OrexPushRegistrationService(
      registrar: registrar,
      tokenStore: store,
      currentToken: () async => null,
      tokenChanges: changes.stream,
      accountKey: () => '@user:example.org|DEVICE',
      appId: config.appId,
      config: () => null,
    );

    await service.start();
    await service.unregisterBeforeLogout();

    expect(registrar.calls, ['unregister:token-old']);
    expect(await store.read('@user:example.org|DEVICE'), isNull);

    await service.dispose();
    await changes.close();
  });

  test('logout unregisters stored and current pushkeys then clears state', () async {
    final registrar = _FakeRegistrar();
    final store = _MemoryTokenStore()
      ..values['@user:example.org|DEVICE'] = 'token-old';
    final changes = StreamController<String>.broadcast();
    final service = OrexPushRegistrationService(
      registrar: registrar,
      tokenStore: store,
      currentToken: () async => 'token-current',
      tokenChanges: changes.stream,
      accountKey: () => '@user:example.org|DEVICE',
      appId: config.appId,
      config: () => config,
    );

    await service.start();
    await service.unregisterBeforeLogout();

    expect(registrar.calls.toSet(), {
      'unregister:token-old',
      'unregister:token-current',
    });
    expect(await store.read('@user:example.org|DEVICE'), isNull);

    await service.dispose();
    await changes.close();
  });
}

class _FakeRegistrar implements OrexPushRegistrar {
  _FakeRegistrar({this.onFirstRegister, this.throwOnUnregister = false});

  final Future<void>? onFirstRegister;
  bool throwOnUnregister;
  final List<String> calls = <String>[];
  final Completer<void> firstRegisterStarted = Completer<void>();
  var _registerCount = 0;

  @override
  Future<void> register({
    required String token,
    required OrexPushRegistrationConfig config,
  }) async {
    calls.add('register:$token');
    _registerCount++;
    if (_registerCount == 1) {
      if (!firstRegisterStarted.isCompleted) firstRegisterStarted.complete();
      final pending = onFirstRegister;
      if (pending != null) await pending;
    }
  }

  @override
  Future<void> unregister({required String token, required String appId}) async {
    calls.add('unregister:$token');
    if (throwOnUnregister) throw StateError('unregister failed');
  }
}

class _MemoryTokenStore implements OrexPushTokenStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> clear(String accountKey) async {
    values.remove(accountKey);
  }

  @override
  Future<String?> read(String accountKey) async => values[accountKey];

  @override
  Future<void> write(String accountKey, String token) async {
    values[accountKey] = token;
  }
}
