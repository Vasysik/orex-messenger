import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

import '../../core/matrix/matrix_service.dart';
import '../../shared/theme/glass.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/theme/theme_controller.dart';
import '../../shared/widgets/mxc_avatar.dart';
import '../../shared/widgets/orex_settings_components.dart';
import 'devices_screen.dart';
import 'key_storage_screen.dart';
import 'verify_session_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.matrix,
    required this.theme,
  });

  final MatrixService matrix;
  final ThemeController theme;

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
    final controller = TextEditingController(text: _profile?.displayName ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Имя профиля'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Как вас называть'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await widget.matrix.setDisplayName(name);
    await _loadProfile(fresh: true);
  }

  Future<String?> _askPassword(BuildContext context) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Подтвердите паролем'),
        content: TextField(
          controller: c,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(hintText: 'Пароль от аккаунта'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('ОК'),
          ),
        ],
      ),
    );
  }

  /// Полный принудительный сброс серверных настроек безопасности.
  Future<void> _resetSecurityDialog() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Сбросить серверные настройки безопасности?'),
        content: const Text(
          'Это действие удалит текущие серверные настройки безопасности: ключ восстановления, кросс-подпись и резервные копии ключей.\n\n'
          'Все остальные ваши сессии станут недоверенными. Будет сгенерирован совершенно новый ключ восстановления. Продолжить?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFCF6679)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Сбросить настройки'),
          ),
        ],
      ),
    );

    if (ok != true) return;
    if (!mounted) return;

    final password = await _askPassword(context);
    if (password == null || password.isEmpty) return;
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: OrexColors.copper),
      ),
    );

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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка сброса: $e')),
        );
      }
    }
  }

  Future<void> _showNewRecoveryKey(String key) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Новый ключ восстановления'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Серверные настройки безопасности успешно сброшены. Создан новый ключ восстановления. '
              'Запишите его и храните в надёжном месте. Без него расшифровать переписку на новых сессиях будет невозможно.',
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                key,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 15),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: key));
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(
                      content: Text('Ключ скопирован в буфер обмена')),
                );
              }
            },
            child: const Text('Копировать'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Я сохранил'),
          ),
        ],
      ),
    );
  }

  /// Диалог смены пароля аккаунта с валидацией полей.
  Future<void> _changePasswordDialog() async {
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Смена пароля'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: oldCtrl,
                  obscureText: true,
                  decoration:
                      const InputDecoration(labelText: 'Текущий пароль'),
                  validator: (v) => (v == null || v.isEmpty)
                      ? 'Введите текущий пароль'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: newCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Новый пароль'),
                  validator: (v) => (v == null || v.length < 6)
                      ? 'Пароль должен быть от 6 символов'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: confirmCtrl,
                  obscureText: true,
                  decoration:
                      const InputDecoration(labelText: 'Подтвердите пароль'),
                  validator: (v) =>
                      v != newCtrl.text ? 'Пароли не совпадают' : null,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('Сменить'),
          ),
        ],
      ),
    );

    if (ok != true) return;
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: OrexColors.copper),
      ),
    );
    try {
      await widget.matrix.changePassword(
        currentPassword: oldCtrl.text,
        newPassword: newCtrl.text,
      );
      if (mounted) {
        Navigator.pop(context); // закрываем индикатор
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Пароль изменён успешно')),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // закрываем индикатор
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка смены пароля: $e')),
        );
      }
    }
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выйти из аккаунта?'),
        content:
            const Text('Текущая сессия будет завершена на этом устройстве.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFCF6679)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );
    if (ok != true) return;
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
              children: [
                _ThemeSelector(theme: widget.theme),
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
                        builder: (_) => KeyStorageScreen(matrix: widget.matrix),
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

    return GlassPanel(
      borderRadius: 22,
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          GestureDetector(
            onTap: savingAvatar ? null : onAvatar,
            child: Stack(
              alignment: Alignment.center,
              children: [
                MxcAvatar(
                  matrix: matrix,
                  name: name,
                  mxc: profile?.avatarUrl,
                  size: 72,
                ),
                if (savingAvatar)
                  const CircularProgressIndicator(color: OrexColors.cream),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: OrexColors.walnutDeep,
                    ),
                    child: const Icon(Icons.photo_camera,
                        size: 14, color: OrexColors.cream),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontSize: 18)),
                const SizedBox(height: 2),
                Text(client.userID ?? '',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          IconButton(
            onPressed: onName,
            icon: const Icon(Icons.edit, color: OrexColors.copper),
          ),
        ],
      ),
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
                    value: ThemeMode.system, icon: Icon(Icons.brightness_auto)),
                ButtonSegment(
                    value: ThemeMode.light, icon: Icon(Icons.light_mode)),
                ButtonSegment(
                    value: ThemeMode.dark, icon: Icon(Icons.dark_mode)),
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
