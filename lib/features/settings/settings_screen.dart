import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/matrix_service.dart';
import '../../theme/glass.dart';
import '../../theme/orex_theme.dart';
import '../../theme/theme_controller.dart';
import '../../widgets/mxc_avatar.dart';
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
    final controller =
        TextEditingController(text: _profile?.displayName ?? '');
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

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выйти из аккаунта?'),
        content: const Text('Текущая сессия будет завершена на этом устройстве.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFCF6679)),
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
            _SectionCard(
              title: 'Оформление',
              children: [
                _ThemeSelector(theme: widget.theme),
              ],
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: 'Безопасность',
              children: [
                _Tile(
                  icon: widget.matrix.encryptionEnabled
                      ? Icons.lock
                      : Icons.lock_open,
                  title: 'Сквозное шифрование',
                  subtitle: widget.matrix.encryptionEnabled
                      ? 'Включено (vodozemac)'
                      : 'Недоступно — vodozemac не инициализирован',
                ),
                if (widget.matrix.encryptionEnabled)
                  _Tile(
                    icon: widget.matrix.isThisSessionVerified
                        ? Icons.verified_user
                        : Icons.gpp_maybe,
                    title: widget.matrix.isThisSessionVerified
                        ? 'Эта сессия подтверждена'
                        : 'Подтвердить эту сессию',
                    subtitle: widget.matrix.isThisSessionVerified
                        ? 'Другие клиенты доверяют этой сессии · открыть'
                        : 'Иначе другие клиенты считают её непроверенной',
                    // Всегда доступно: даже если статус определился неточно,
                    // отсюда можно подписать сессию ключом восстановления.
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
                  _Tile(
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
                _Tile(
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
            _SectionCard(
              title: 'Аккаунт',
              children: [
                _Tile(
                  icon: Icons.alternate_email,
                  title: 'Matrix ID',
                  subtitle: widget.matrix.userId,
                ),
                _Tile(
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

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 8),
          child: Text(title.toUpperCase(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    letterSpacing: 1.1,
                    color: OrexColors.copper,
                    fontWeight: FontWeight.w700,
                  )),
        ),
        GlassPanel(
          borderRadius: 20,
          child: Column(children: children),
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? const Color(0xFFCF6679) : null;
    return ListTile(
      leading: Icon(icon, color: color ?? OrexColors.copper),
      title: Text(title, style: TextStyle(color: color)),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing: onTap != null
          ? const Icon(Icons.chevron_right, size: 20)
          : null,
      onTap: onTap,
    );
  }
}
