import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/matrix/matrix_service.dart';
import '../../core/config/app_version.dart';
import '../../shared/theme/glass.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/theme/theme_controller.dart';
import '../../shared/widgets/orex_dialogs.dart';
import '../../shared/widgets/orex_profile_card.dart';
import '../../shared/widgets/orex_settings_components.dart';
import 'audio_devices_screen.dart';
import 'devices_screen.dart';
import 'key_storage_screen.dart';
import 'verify_session_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.matrix,
    required this.theme,
    required this.version,
  });

  final MatrixService matrix;
  final ThemeController theme;
  final OrexAppVersion version;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Profile? _profile;
  bool _savingAvatar = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile({bool fresh = false}) async {
    final p = await widget.matrix.ownProfile(fresh: fresh);
    if (mounted) setState(() => _profile = p);
  }

  Future<void> _pickAvatar() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final files = res?.files ?? const [];
    final file = files.isNotEmpty ? files.first : null;
    if (file?.bytes == null) return;
    setState(() => _savingAvatar = true);
    try {
      await widget.matrix.setAvatarBytes(file!.bytes!, file.name);
      await _loadProfile(fresh: true);
    } finally {
      if (mounted) setState(() => _savingAvatar = false);
    }
  }

  Future<void> _editName() async {
    final name = await showOrexTextInputDialog(
      context,
      title: 'Имя профиля',
      initialValue: _profile?.displayName,
      hintText: 'Как вас называть',
      confirmLabel: 'Сохранить',
      trim: true,
    );
    if (name == null || name.isEmpty) return;
    await widget.matrix.setDisplayName(name);
    await _loadProfile(fresh: true);
  }

  Future<String?> _askPassword(BuildContext context) {
    return showOrexTextInputDialog(
      context,
      title: 'Подтвердите паролем',
      hintText: 'Пароль от аккаунта',
      obscureText: true,
      barrierDismissible: false,
    );
  }

  /// Полный принудительный сброс серверных настроек безопасности.
  Future<void> _resetSecurityDialog() async {
    final ok = await showOrexConfirmDialog(
      context,
      title: 'Сбросить серверные настройки безопасности?',
      message:
          'Это действие удалит текущие серверные настройки безопасности: ключ восстановления, кросс-подпись и резервные копии ключей.\n\n'
          'Все остальные ваши сессии станут недоверенными. Будет сгенерирован совершенно новый ключ восстановления. Продолжить?',
      confirmLabel: 'Сбросить настройки',
      danger: true,
    );

    if (!ok) return;
    if (!mounted) return;

    final password = await _askPassword(context);
    if (password == null || password.isEmpty) return;
    if (!mounted) return;

    showOrexBlockingProgressDialog(context);

    try {
      final newKey = await widget.matrix.resetSecurity(
        askPassword: () async => password,
      );
      if (mounted) {
        Navigator.pop(context); // закрываем индикатор
        await _showNewRecoveryKey(newKey);
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // закрываем индикатор
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Ошибка сброса: $e')));
      }
    }
  }

  Future<void> _showNewRecoveryKey(String key) {
    return showOrexRecoveryKeyDialog(
      context,
      title: 'Новый ключ восстановления',
      message:
          'Серверные настройки безопасности успешно сброшены. Создан новый '
          'ключ восстановления. Запишите его и храните в надёжном месте. '
          'Без него расшифровать переписку на новых сессиях будет невозможно.',
      recoveryKey: key,
    );
  }

  /// Диалог смены пароля аккаунта с валидацией полей.
  Future<void> _changePasswordDialog() async {
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final passwords =
        await showOrexStatefulFormDialog<
              ({String currentPassword, String newPassword})
            >(
              context,
              title: 'Смена пароля',
              confirmLabel: 'Сменить',
              contentBuilder: (ctx, setDialogState) => Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: oldCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Текущий пароль',
                      ),
                      validator: (v) => (v == null || v.isEmpty)
                          ? 'Введите текущий пароль'
                          : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: newCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Новый пароль',
                      ),
                      validator: (v) => (v == null || v.length < 6)
                          ? 'Пароль должен быть от 6 символов'
                          : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: confirmCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Подтвердите пароль',
                      ),
                      validator: (v) =>
                          v != newCtrl.text ? 'Пароли не совпадают' : null,
                    ),
                  ],
                ),
              ),
              onSubmit: () {
                if (!(formKey.currentState?.validate() ?? false)) return null;
                return (
                  currentPassword: oldCtrl.text,
                  newPassword: newCtrl.text,
                );
              },
            )
            .whenComplete(() {
              oldCtrl.dispose();
              newCtrl.dispose();
              confirmCtrl.dispose();
            });

    if (passwords == null) return;
    if (!mounted) return;

    showOrexBlockingProgressDialog(context);
    try {
      await widget.matrix.changePassword(
        currentPassword: passwords.currentPassword,
        newPassword: passwords.newPassword,
      );
      if (mounted) {
        Navigator.pop(context); // закрываем индикатор
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Пароль изменён успешно')));
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // закрываем индикатор
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Ошибка смены пароля: $e')));
      }
    }
  }

  Future<void> _logout() async {
    final ok = await showOrexConfirmDialog(
      context,
      title: 'Выйти из аккаунта?',
      message: 'Текущая сессия будет завершена на этом устройстве.',
      confirmLabel: 'Выйти',
      danger: true,
    );
    if (!ok) return;
    await widget.matrix.logout();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Text('Настройки'),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _ProfileCard(
              matrix: widget.matrix,
              profile: _profile,
              client: widget.matrix.client,
              savingAvatar: _savingAvatar,
              onAvatar: _pickAvatar,
              onName: _editName,
            ),
            const SizedBox(height: 16),
            OrexSettingsSection(
              title: 'Оформление',
              children: [_ThemeSelector(theme: widget.theme)],
            ),
            const SizedBox(height: 16),
            OrexSettingsSection(
              title: 'Звук и звонки',
              children: [
                OrexSettingsTile(
                  icon: Icons.settings_voice,
                  title: 'Аудиоустройства',
                  subtitle: 'Микрофон, вывод звука и проверка устройств',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => AudioDevicesScreen(matrix: widget.matrix),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            OrexSettingsSection(
              title: 'Безопасность',
              children: [
                OrexSettingsTile(
                  icon: widget.matrix.encryptionEnabled
                      ? Icons.lock
                      : Icons.lock_open,
                  title: 'Сквозное шифрование',
                  subtitle: widget.matrix.encryptionEnabled
                      ? 'Включено (vodozemac)'
                      : 'Недоступно — vodozemac не инициализирован',
                ),
                if (widget.matrix.encryptionEnabled)
                  OrexSettingsTile(
                    icon: widget.matrix.isThisSessionVerified
                        ? Icons.verified_user
                        : Icons.gpp_maybe,
                    title: widget.matrix.isThisSessionVerified
                        ? 'Эта сессия подтверждена'
                        : 'Подтвердить эту сессию',
                    subtitle: widget.matrix.isThisSessionVerified
                        ? 'Другие клиенты доверяют этой сессии · открыть'
                        : 'Иначе другие клиенты считают её непроверенной',
                    onTap: () => Navigator.of(context)
                        .push(
                          MaterialPageRoute(
                            builder: (_) =>
                                VerifySessionScreen(matrix: widget.matrix),
                          ),
                        )
                        .then((_) {
                          if (mounted) setState(() {});
                        }),
                  ),
                if (widget.matrix.encryptionEnabled)
                  OrexSettingsTile(
                    icon: widget.matrix.keyBackupEnabled
                        ? Icons.cloud_done
                        : Icons.cloud_off,
                    title: 'Хранилище ключей',
                    subtitle: widget.matrix.keyBackupEnabled
                        ? 'Бэкап ключей сообщений: статус и резервные копии'
                        : 'Выключено — настройте, чтобы не терять переписку',
                    onTap: () => Navigator.of(context)
                        .push(
                          MaterialPageRoute(
                            builder: (_) =>
                                KeyStorageScreen(matrix: widget.matrix),
                          ),
                        )
                        .then((_) {
                          if (mounted) setState(() {});
                        }),
                  ),
                OrexSettingsTile(
                  icon: Icons.devices,
                  title: 'Устройства аккаунта',
                  subtitle: 'Просмотр и управление сессиями',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DevicesScreen(matrix: widget.matrix),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),
            OrexSettingsSection(
              title: 'О приложении',
              children: [
                OrexSettingsTile(
                  icon: Icons.info_outline,
                  title: 'Orex Messenger',
                  subtitle: widget.version.settingsSubtitle,
                ),
              ],
            ),
            const SizedBox(height: 16),
            OrexSettingsSection(
              title: 'Аккаунт',
              children: [
                OrexSettingsTile(
                  icon: Icons.alternate_email,
                  title: 'Matrix ID',
                  subtitle: widget.matrix.userId,
                ),
                OrexSettingsTile(
                  icon: Icons.lock_person,
                  title: 'Сменить пароль',
                  subtitle: 'Изменить текущий пароль от аккаунта',
                  onTap: _changePasswordDialog,
                ),
                OrexSettingsTile(
                  icon: Icons.security_update_warning,
                  title: 'Сбросить серверные настройки безопасности',
                  subtitle:
                      'Ключ восстановления, кросс-подпись и резервные копии',
                  onTap: _resetSecurityDialog,
                ),
                OrexSettingsTile(
                  icon: Icons.logout,
                  title: 'Выйти',
                  danger: true,
                  onTap: _logout,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.matrix,
    required this.profile,
    required this.client,
    required this.savingAvatar,
    required this.onAvatar,
    required this.onName,
  });

  final MatrixService matrix;
  final Profile? profile;
  final Client client;
  final bool savingAvatar;
  final VoidCallback onAvatar;
  final VoidCallback onName;

  @override
  Widget build(BuildContext context) {
    final name = profile?.displayName ?? client.userID ?? '';

    return OrexProfileCard(
      matrix: matrix,
      name: name,
      subtitle: client.userID ?? '',
      avatar: profile?.avatarUrl,
      busy: savingAvatar,
      onAvatar: savingAvatar ? null : onAvatar,
      onEdit: onName,
    );
  }
}

class _ThemeSelector extends StatelessWidget {
  const _ThemeSelector({required this.theme});
  final ThemeController theme;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: theme,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.palette_outlined, color: OrexColors.copper),
            const SizedBox(width: 14),
            const Expanded(child: Text('Тема приложения')),
            SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode),
                ),
              ],
              selected: {theme.mode},
              onSelectionChanged: (s) => theme.setMode(s.first),
            ),
          ],
        ),
      ),
    );
  }
}
