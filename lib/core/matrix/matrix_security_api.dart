part of 'matrix_service.dart';

extension MatrixSecurityApi on MatrixService {
  // ---------------------------------------------------------------------------
  // Шифрование и проверка ТЕКУЩЕЙ сессии (кросс-подпись)
  // ---------------------------------------------------------------------------

  /// E2EE доступно, только если vodozemac был инициализирован ДО client.init().
  bool get encryptionEnabled => client.encryptionEnabled;

  /// Дождаться, пока ключи устройств подгрузятся из БД/сети (иначе статусы ниже
  /// могут быть «ложно непроверенными» сразу после логина).
  Future<void> ensureKeysLoaded() =>
      client.userDeviceKeysLoading ?? Future.value();

  /// Включено ли «хранилище ключей» (онлайн-бэкап ключей сообщений). Когда
  /// включено, история восстанавливается на новых устройствах после проверки —
  /// сообщения не «теряются». Настраивается тем же bootstrap, что и кросс-подпись.
  bool get keyBackupEnabled =>
      (client.encryption?.keyManager.enabled ?? false) &&
      _serverBackupVersion != null &&
      !_backupDisabledByUser;

  /// Загрузка актуальной версии бэкапа с сервера.
  /// Вызывается при старте и после операций включения/выключения бэкапа.
  Future<void> updateServerBackupVersion() async {
    _checkedServerBackup = true;
    // Если пользователь явно отключил бэкап в этой сессии — не «переоткрываем».
    if (_backupDisabledByUser) return;
    try {
      final currentBackup = await client.getRoomKeysVersionCurrent();
      _serverBackupVersion = currentBackup.version;
    } catch (_) {
      _serverBackupVersion = null;
    }
    _emitChange();
  }

  /// Скачать ВЕСЬ онлайн-бэкап ключей и расшифровать старую историю. Проверка
  /// сессии восстанавливает лишь часть ключей; этот вызов подтягивает все, что
  /// есть в бэкапе (включая сообщения прошлых сессий) — иначе на новой сессии
  /// видны только сообщения за её собственное время.
  Future<void> restoreKeyBackup() async {
    final km = client.encryption?.keyManager;
    if (km == null || _serverBackupVersion == null || _backupDisabledByUser) {
      return;
    }
    try {
      if (await km.isCached()) {
        await km.loadAllKeys();
      }
    } catch (e) {
      debugPrint('Не удалось загрузить ключи из бэкапа: $e');
    }
    _emitChange();
  }

  // --- Управление хранилищем ключей (бэкап сообщений) ---

  String _accountPrefKey(String key) {
    final userId = client.userID;
    if (userId == null || userId.isEmpty) return key;
    return '$key:$userId';
  }

  Future<void> _loadBackupPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      autoBackup = prefs.getBool(_kAutoBackup) ?? false;
      _backupDisabledByUser =
          prefs.getBool(_accountPrefKey(_kBackupDisabledByUser)) ?? false;
      final ms = prefs.getInt(_kLastBackup);
      if (ms != null) lastBackup = DateTime.fromMillisecondsSinceEpoch(ms);
      if (autoBackup && !_backupDisabledByUser) {
        _startAutoBackup();
      } else {
        _autoBackupTimer?.cancel();
      }
    } catch (_) {}
  }

  Future<void> _setBackupDisabledByUser(bool disabled) async {
    _backupDisabledByUser = disabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_accountPrefKey(_kBackupDisabledByUser), disabled);
    } catch (_) {}
  }

  Future<void> _setAutoBackupStored(bool on) async {
    autoBackup = on;
    if (!on) _autoBackupTimer?.cancel();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAutoBackup, on);
    } catch (_) {}
  }

  Future<void> _deleteCurrentServerKeyBackup() async {
    try {
      final currentBackup = await client.getRoomKeysVersionCurrent();
      await client.deleteRoomKeysVersion(currentBackup.version);
    } on MatrixException catch (e) {
      if (e.errcode != 'M_NOT_FOUND') rethrow;
    }

    _serverBackupVersion = null;
    try {
      await client.encryption?.keyManager.getRoomKeysBackupInfo(false);
    } catch (_) {}
  }

  Future<void> _refreshOwnSecurityState() async {
    try {
      await client.oneShotSync().timeout(const Duration(seconds: 8));
      await ensureKeysLoaded().timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('refreshOwnSecurityState failed: $e');
    }
    _emitChange();
  }

  void _startAutoBackup() {
    _autoBackupTimer?.cancel();
    _autoBackupTimer = Timer.periodic(
      const Duration(minutes: 2),
      (_) => _uploadKeys(record: true),
    );
  }

  /// Включить/выключить автоматический бэкап.
  Future<void> setAutoBackup(bool on) async {
    if (on && !keyBackupEnabled) {
      throw StateError('Сначала включите хранилище ключей');
    }
    await _setAutoBackupStored(on);
    _emitChange();
    if (on) {
      _startAutoBackup();
      await _uploadKeys(record: true);
    }
  }

  /// Полный бэкап сейчас: помечаем ВСЕ ключи к выгрузке и загружаем в хранилище.
  Future<void> backupNow() async {
    backupInProgress = true;
    _emitChange();
    try {
      await client.database
          .markInboundGroupSessionsAsNeedingUpload()
          .timeout(const Duration(seconds: 10));
      await _uploadKeys(record: true).timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('backupNow failed: $e');
    } finally {
      backupInProgress = false;
      _emitChange();
    }
  }

  Future<void> _uploadKeys({bool record = false}) async {
    final km = client.encryption?.keyManager;
    if (km == null ||
        !km.enabled ||
        _serverBackupVersion == null ||
        _backupDisabledByUser) {
      return;
    }
    try {
      await client.getRoomKeysVersionCurrent();
      await km.uploadInboundGroupSessions();
      await _recordLastBackupTime(record);
    } on MatrixException catch (e) {
      // Версия бэкапа на сервере исчезла. Не пересоздаём её фоном:
      // хранилище ключей включается только явным действием пользователя.
      if (e.errcode == 'M_NOT_FOUND') {
        _serverBackupVersion = null;
        await _setAutoBackupStored(false);
        await _setBackupDisabledByUser(true);
        _emitChange();
      } else {
        debugPrint('uploadInboundGroupSessions failed: $e');
      }
    } catch (e) {
      debugPrint('uploadInboundGroupSessions failed: $e');
    }
  }

  /// Сохраняет время последнего бэкапа в память и SharedPreferences.
  Future<void> _recordLastBackupTime(bool record) async {
    if (!record) return;
    lastBackup = DateTime.now();
    _emitChange();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kLastBackup, lastBackup!.millisecondsSinceEpoch);
    } catch (_) {}
  }

  /// Включить хранилище ключей на сервере.
  ///
  /// ВАЖНО: если бэкап уже существует на сервере — НЕ пересоздаём SSSS и не
  /// генерируем новый ключ восстановления. Просто загружаем ключи в
  /// существующий бэкап. Новый ключ возвращается ТОЛЬКО при первичной настройке.
  ///
  /// [askPassword] вызывается, когда серверу нужен пароль (UIA) при публикации
  /// ключей подписи. [recoveryKey] — уже введённый ключ для разблокировки SSSS.
  Future<String?> enableKeyBackup({
    required Future<String?> Function() askPassword,
    String? recoveryKey,
  }) async {
    final encryption = client.encryption;
    if (encryption == null) {
      throw StateError('Шифрование не инициализировано');
    }

    final wasBackupDisabled = _backupDisabledByUser;

    // Проверяем, есть ли уже бэкап на сервере.
    // Если есть — просто подключаемся к нему, не трогая SSSS и ключ восстановления.
    try {
      final existing = await client.getRoomKeysVersionCurrent();
      if (existing.version.isNotEmpty) {
        _serverBackupVersion = existing.version;
        await _setBackupDisabledByUser(false);
        _emitChange();
        await _uploadKeys(record: true);
        // null — новый ключ НЕ генерировался, диалог «сохраните ключ» не показываем.
        return null;
      }
    } catch (_) {
      // M_NOT_FOUND или сетевая ошибка — бэкапа нет, создаём ниже через bootstrap.
    }

    // Бэкапа нет — запускаем полный bootstrap для создания SSSS + бэкапа.
    final completer = Completer<String?>();
    var createdNewSsss = false;

    // UIA: сервер может потребовать пароль при публикации сигнатуры бэкапа
    final uiaSub = client.onUiaRequest.stream.listen((uia) async {
      if (uia.state != UiaRequestState.waitForUser) return;
      if (!uia.nextStages.contains(AuthenticationTypes.password)) {
        uia.cancel(
            Exception('Неподдерживаемый способ входа: ${uia.nextStages}'));
        return;
      }
      final pw = await askPassword();
      if (pw == null || pw.isEmpty) {
        uia.cancel(Exception('Отменено пользователем'));
        return;
      }
      await uia.completeStage(
        AuthenticationPassword(
          identifier: AuthenticationUserIdentifier(user: client.userID!),
          password: pw,
          session: uia.session,
        ),
      );
    });

    encryption.bootstrap(
      onUpdate: (b) async {
        try {
          switch (b.state) {
            case BootstrapState.askNewSsss:
              createdNewSsss = true;
              await b.newSsss();
              break;
            case BootstrapState.askUseExistingSsss:
              // SSSS уже есть — используем, НЕ пересоздаём и не генерируем новый ключ.
              b.useExistingSsss(true);
              break;
            case BootstrapState.openExistingSsss:
              final key = recoveryKey?.trim();
              final ssss = b.newSsssKey;
              if (ssss != null && !ssss.isUnlocked) {
                if (key == null || key.isEmpty) {
                  if (!completer.isCompleted) {
                    completer
                        .completeError(StateError('recovery_key_required'));
                  }
                  break;
                }
                try {
                  await ssss.unlock(recoveryKey: key);
                } catch (_) {
                  await ssss.unlock(passphrase: key);
                }
              }
              await b.openExistingSsss();
              break;
            case BootstrapState.askUnlockSsss:
              final key = recoveryKey?.trim();
              if (key != null && key.isNotEmpty && b.oldSsssKeys != null) {
                bool unlockedAny = false;
                for (final k in b.oldSsssKeys!.values) {
                  try {
                    await k.unlock(recoveryKey: key);
                    unlockedAny = true;
                  } catch (_) {
                    try {
                      await k.unlock(passphrase: key);
                      unlockedAny = true;
                    } catch (_) {}
                  }
                }
                if (unlockedAny) {
                  b.unlockedSsss();
                  break;
                }
              }
              if (!completer.isCompleted) {
                completer.completeError(StateError('recovery_key_required'));
              }
              break;
            case BootstrapState.askBadSsss:
              // Плохой/несовместимый SSSS — требуем ключ, а не молча сносим.
              if (!completer.isCompleted) {
                completer.completeError(StateError('recovery_key_required'));
              }
              break;
            case BootstrapState.askWipeSsss:
              // SSSS уже есть. Для включения backup используем его, а не
              // пересоздаём всю безопасность аккаунта.
              b.wipeSsss(false);
              break;
            case BootstrapState.askWipeCrossSigning:
              await b.wipeCrossSigning(false);
              break;
            case BootstrapState.askWipeOnlineKeyBackup:
              // Серверного backup уже нет (мы проверили выше), но в SSSS мог
              // остаться старый m.megolm_backup.v1. При явном включении
              // создаём новую серверную версию и новый backup-secret.
              b.wipeOnlineKeyBackup(true);
              break;
            case BootstrapState.askSetupCrossSigning:
              await b.askSetupCrossSigning(
                setupMasterKey: true,
                setupSelfSigningKey: true,
                setupUserSigningKey: true,
              );
              break;
            case BootstrapState.askSetupOnlineKeyBackup:
              await b.askSetupOnlineKeyBackup(true);
              break;
            case BootstrapState.done:
              if (!completer.isCompleted) {
                // Возвращаем ключ только если реально создали новый SSSS.
                // При открытии существующего SSSS SDK тоже хранит его в
                // newSsssKey, но это старый recovery key, а не новый.
                completer.complete(
                  createdNewSsss ? b.newSsssKey?.recoveryKey : null,
                );
              }
              break;
            case BootstrapState.error:
              if (!completer.isCompleted) {
                completer.completeError(
                    StateError('Ошибка настройки резервной копии'));
              }
              break;
            case BootstrapState.loading:
              break;
          }
        } catch (e) {
          if (!completer.isCompleted) completer.completeError(e);
        }
      },
    );

    try {
      final key = await completer.future;
      await _setBackupDisabledByUser(false);
      await updateServerBackupVersion();
      return key;
    } finally {
      if (_serverBackupVersion == null) {
        await _setBackupDisabledByUser(wasBackupDisabled);
      }
      await uiaSub.cancel();
    }
  }

  /// Отключить хранилище ключей (удалить текущую версию бэкапа с сервера).
  ///
  /// После вызова _backupDisabledByUser = true, чтобы sync и отложенные
  /// restoreKeyBackup() не «переоткрыли» бэкап автоматически в этой сессии.
  /// SSSS и кросс-подпись не затрагиваются.
  Future<void> disableKeyBackup() async {
    try {
      await _deleteCurrentServerKeyBackup();
    } catch (e) {
      debugPrint('disableKeyBackup failed: $e');
      rethrow;
    }

    // Помечаем: пользователь сам отключил бэкап — sync не должен его «вернуть».
    await _setBackupDisabledByUser(true);
    _serverBackupVersion = null;

    // Выключаем автобэкап, чтобы таймер не пытался грузить в несуществующий бэкап.
    await _setAutoBackupStored(false);
    _emitChange();
  }

  /// На аккаунте настроена кросс-подпись.
  /// Если false — проверять нечем: сперва нужно настроить безопасность
  /// или сделать первичную настройку проверки подлинности.
  bool get crossSigningAvailable =>
      client.encryption?.crossSigning.enabled ?? false;

  /// Эта сессия КРОСС-ПОДПИСАНА master-ключом владельца. Ровно этот признак
  /// смотрят и раздача ключей комнаты, и Element X: пока false — Element пишет
  /// «зашифровано устройством, не проверенным его владельцем».
  ///
  /// ВАЖНО про прошлые попытки: `dk.verified` для своей текущей сессии всегда
  /// true (доверяет себе локально); `signed`/`isUnknownSession` требует, чтобы
  /// master был directVerified — оба давали неверный статус. Корректно —
  /// `hasValidSignatureChain(verifiedByTheirMasterKey: true)`: есть ли валидная
  /// цепочка подписей устройство → SSK → master.
  bool get isThisSessionVerified {
    final dk =
        client.userDeviceKeys[client.userID]?.deviceKeys[client.deviceID];
    return dk?.hasValidSignatureChain(verifiedByTheirMasterKey: true) ?? false;
  }

  /// Нужно ли показать плашку «сессия не подтверждена». Показываем, как только
  /// шифрование включено, а сессия ещё не кросс-подписана — даже если на
  /// аккаунте кросс-подписи ещё нет (тогда экран предложит её НАСТРОИТЬ через
  /// bootstrap; для свежих аккаунтов это и нужно).
  bool get needsSessionVerification =>
      encryptionEnabled && !isThisSessionVerified;

  /// Запустить самопроверку этой сессии с других своих устройств (Element X и
  /// пр.). Они покажут сравнение эмодзи; после успеха кросс-подпишут это
  /// устройство, и в других клиентах оно станет «проверенным».
  Future<KeyVerification> startSelfVerification() async {
    await ensureKeysLoaded();
    final own = client.userDeviceKeys[client.userID];
    if (own == null) {
      throw StateError('Ключи устройства ещё не загружены');
    }
    return own.startVerification();
  }

  /// Подтвердить эту сессию ключом восстановления (или passphrase) — без второго
  /// устройства: разблокируем SSSS и сами кросс-подписываем это устройство.
  Future<void> verifyWithRecoveryKey(String keyOrPassphrase) async {
    final crossSigning = client.encryption?.crossSigning;
    if (crossSigning == null) {
      throw StateError('Шифрование не инициализировано');
    }
    await crossSigning.selfSign(keyOrPassphrase: keyOrPassphrase.trim());
    await _refreshOwnSecurityState();
    // Ключ восстановления разблокировал SSSS → тянем всю историю из бэкапа.
    await restoreKeyBackup();
  }

  /// ПЕРВИЧНАЯ настройка проверки подлинности: создаёт кросс-подпись
  /// (master/self/user-signing) и ключ восстановления (SSSS), после чего эта
  /// сессия становится доверенной. Онлайн-хранилище ключей здесь не создаётся:
  /// пользователь включает его отдельным действием. Возвращает КЛЮЧ ВОССТАНОВЛЕНИЯ — его нужно
  /// сохранить (это и есть тот самый ключ, которым потом подтверждают сессии).
  ///
  /// [askPassword] вызывается, когда серверу нужен пароль (UIA) для загрузки
  /// ключей подписи.
  ///
  /// БЕЗОПАСНОСТЬ: если на аккаунте УЖЕ есть данные безопасности
  /// (SSSS/кросс-подпись/бэкап) — метод НЕ перезатирает их (иначе слетело бы
  /// доверие на других сессиях), а бросает ошибку. В этом случае нужно не
  /// настраивать заново, а подтвердить сессию ключом восстановления.
  Future<String> setupCrossSigning({
    required Future<String?> Function() askPassword,
  }) async {
    final encryption = client.encryption;
    if (encryption == null) {
      throw StateError('Шифрование не инициализировано');
    }
    if (crossSigningAvailable) {
      throw StateError(
        'Кросс-подпись уже настроена — подтвердите сессию ключом восстановления',
      );
    }

    final completer = Completer<String>();
    void fail(Object e) {
      if (!completer.isCompleted) completer.completeError(e);
    }

    // UIA: сервер требует пароль при загрузке cross-signing ключей.
    final uiaSub = client.onUiaRequest.stream.listen((uia) async {
      if (uia.state != UiaRequestState.waitForUser) return;
      if (!uia.nextStages.contains(AuthenticationTypes.password)) {
        uia.cancel(
            Exception('Неподдерживаемый способ входа: ${uia.nextStages}'));
        return;
      }
      final pw = await askPassword();
      if (pw == null || pw.isEmpty) {
        uia.cancel(Exception('Отменено'));
        return;
      }
      await uia.completeStage(
        AuthenticationPassword(
          identifier: AuthenticationUserIdentifier(user: client.userID!),
          password: pw,
          session: uia.session,
        ),
      );
    });

    encryption.bootstrap(onUpdate: (b) async {
      try {
        switch (b.state) {
          case BootstrapState.askNewSsss:
            // Без passphrase → SDK сгенерирует ключ восстановления.
            await b.newSsss();
            break;
          case BootstrapState.askSetupCrossSigning:
            await b.askSetupCrossSigning(
              setupMasterKey: true,
              setupSelfSigningKey: true,
              setupUserSigningKey: true,
            );
            break;
          case BootstrapState.askSetupOnlineKeyBackup:
            await b.askSetupOnlineKeyBackup(false);
            break;
          case BootstrapState.done:
            if (!completer.isCompleted) {
              completer.complete(b.newSsssKey?.recoveryKey ?? '');
            }
            break;
          case BootstrapState.error:
            fail(StateError('Не удалось настроить кросс-подпись'));
            break;
          case BootstrapState.loading:
            break;
          default:
            // askWipe* / askUseExisting / askUnlock / askBadSsss / openExisting —
            // значит данные уже есть. НЕ трогаем (риск потери ключей).
            fail(
              StateError(
                'На аккаунте уже есть данные безопасности — не трогаю их, чтобы '
                'не потерять ключи. Подтвердите эту сессию ключом восстановления '
                'или сбросьте безопасность в Orex.',
              ),
            );
        }
      } catch (e) {
        fail(e);
      }
    });

    try {
      final key = await completer.future;
      _serverBackupVersion = null;
      await _setBackupDisabledByUser(true);
      await _refreshOwnSecurityState();
      return key;
    } finally {
      await uiaSub.cancel();
    }
  }

  /// Полный принудительный сброс настроек безопасности (SSSS, кросс-подпись, бэкапы)
  /// и генерация новой конфигурации с новым ключом восстановления.
  ///
  /// После сброса:
  ///   - бэкап ключей НЕ создаётся автоматически (пользователь включит сам).
  ///   - _serverBackupVersion и _backupDisabledByUser сбрасываются,
  ///     чтобы пользователь мог заново включить бэкап через UI.
  Future<String> resetSecurity({
    required Future<String?> Function() askPassword,
  }) async {
    final encryption = client.encryption;
    if (encryption == null) {
      throw StateError('Шифрование не инициализировано');
    }

    final resetPassword = await askPassword();
    if (resetPassword == null || resetPassword.isEmpty) {
      throw StateError('Отменено пользователем');
    }

    final completer = Completer<String>();

    final uiaSub = client.onUiaRequest.stream.listen((uia) async {
      if (uia.state != UiaRequestState.waitForUser) return;
      if (!uia.nextStages.contains(AuthenticationTypes.password)) {
        uia.cancel(
            Exception('Неподдерживаемый способ входа: ${uia.nextStages}'));
        return;
      }
      await uia.completeStage(
        AuthenticationPassword(
          identifier: AuthenticationUserIdentifier(user: client.userID!),
          password: resetPassword,
          session: uia.session,
        ),
      );
    });

    encryption.bootstrap(onUpdate: (b) async {
      try {
        switch (b.state) {
          case BootstrapState.askUseExistingSsss:
            // Отказываемся от старого SSSS на сервере, чтобы запустить Wipe-цепочку
            b.useExistingSsss(false);
            break;
          case BootstrapState.openExistingSsss:
          case BootstrapState.askUnlockSsss:
          case BootstrapState.askWipeSsss:
            b.wipeSsss(true);
            break;
          case BootstrapState.askWipeCrossSigning:
            b.wipeCrossSigning(true);
            break;
          case BootstrapState.askWipeOnlineKeyBackup:
            b.wipeOnlineKeyBackup(true);
            break;
          case BootstrapState.askNewSsss:
            await b.newSsss();
            break;
          case BootstrapState.askBadSsss:
            b.ignoreBadSecrets(true);
            break;
          case BootstrapState.askSetupCrossSigning:
            await b.askSetupCrossSigning(
              setupMasterKey: true,
              setupSelfSigningKey: true,
              setupUserSigningKey: true,
            );
            break;
          case BootstrapState.askSetupOnlineKeyBackup:
            // После сброса бэкап НЕ создаём — пользователь включит вручную.
            await b.askSetupOnlineKeyBackup(false);
            break;
          case BootstrapState.done:
            if (!completer.isCompleted) {
              completer.complete(b.newSsssKey?.recoveryKey ?? '');
            }
            break;
          case BootstrapState.error:
            if (!completer.isCompleted) {
              completer.completeError(
                  StateError('Не удалось выполнить сброс безопасности'));
            }
            break;
          case BootstrapState.loading:
            break;
        }
      } catch (e) {
        if (!completer.isCompleted) completer.completeError(e);
      }
    });

    try {
      final key = await completer.future;
      await _deleteCurrentServerKeyBackup();

      // После сброса бэкапа нет — фиксируем локально, что хранилище выключено.
      // Пользователь сможет включить его заново нажатием на карточку в UI.
      _serverBackupVersion = null;
      await _setBackupDisabledByUser(true);

      // Выключаем автобэкап — после сброса он теряет смысл до нового включения.
      await _setAutoBackupStored(false);

      await _refreshOwnSecurityState();
      return key;
    } finally {
      await uiaSub.cancel();
    }
  }


}
