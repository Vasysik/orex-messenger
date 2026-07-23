/// Показывает предупреждение, если серверное хранилище ключей отсутствует
/// или автоматическая отправка новых ключей выключена.
///
/// Ручное отключение не скрывает предупреждение: в этом состоянии история
/// зашифрованных сообщений может не восстановиться на новом устройстве.
bool shouldRecommendOrexKeyBackup({
  required bool encryptionEnabled,
  required bool statusKnown,
  required bool keyBackupEnabled,
  required bool autoBackupEnabled,
}) =>
    encryptionEnabled &&
    statusKnown &&
    (!keyBackupEnabled || !autoBackupEnabled);

/// Приоритет единой верхней системной плашки Orex.
enum OrexHomeNoticeKind {
  verification,
  update,
  keyBackup,
  accountEmail,
}

/// Возвращает единственную плашку с наивысшим приоритетом.
///
/// Во время активного/запускающегося звонка плашки не показываются, чтобы не
/// сдвигать интерфейс управления вызовом.
OrexHomeNoticeKind? selectOrexHomeNotice({
  required bool callIsBusy,
  required bool needsVerification,
  required bool updateAvailable,
  required bool recommendKeyBackup,
  required bool recommendAccountEmail,
}) {
  if (callIsBusy) return null;
  if (needsVerification) return OrexHomeNoticeKind.verification;
  if (updateAvailable) return OrexHomeNoticeKind.update;
  if (recommendKeyBackup) return OrexHomeNoticeKind.keyBackup;
  if (recommendAccountEmail) return OrexHomeNoticeKind.accountEmail;
  return null;
}
