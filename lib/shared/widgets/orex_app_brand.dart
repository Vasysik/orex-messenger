import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../core/config/app_version.dart';
import '../../core/config/orex_config.dart';
import '../theme/orex_theme.dart';

String get orexAppName => OrexConfig.appDisplayName;
const String orexAppSlogan = 'Тепло. Быстро. Децентрализованно.';
const String orexAppIconAsset = 'assets/icon/app_icon.png';

/// Фирменная иконка Orex с единым размером, скруглением и мягким медным glow.
/// Используется на bootstrap/auth-поверхностях, чтобы splash и регистрация не
/// расходились по оформлению.
class OrexAppIcon extends StatelessWidget {
  const OrexAppIcon({super.key, this.size = 120});

  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.24);
    final decodeWidth = (size * MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(64, 1024)
        .toInt();

    return Semantics(
      image: true,
      label: 'Иконка приложения $orexAppName',
      child: SizedBox.square(
        dimension: size,
        child: Image.asset(
          orexAppIconAsset,
          fit: BoxFit.cover,
          cacheWidth: kIsWeb ? null : decodeWidth,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            final decorated = Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow: [
                  BoxShadow(
                    color: OrexColors.copper.withValues(alpha: 0.28),
                    blurRadius: size * 0.25,
                    offset: Offset(0, size * 0.08),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: child,
            );
            if (wasSynchronouslyLoaded) return decorated;
            return AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              child: decorated,
            );
          },
          errorBuilder: (_, __, ___) => const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// Единый бренд-блок для запуска, входа и регистрации.
class OrexBrandHeader extends StatelessWidget {
  const OrexBrandHeader({
    super.key,
    this.version,
    this.iconSize = 120,
    this.titleFontSize = 22,
    this.textAlign = TextAlign.center,
    this.showVersion = true,
  }) : assert(!showVersion || version != null);

  final OrexAppVersion? version;
  final double iconSize;
  final double titleFontSize;
  final TextAlign textAlign;
  final bool showVersion;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        OrexAppIcon(size: iconSize),
        const SizedBox(height: 16),
        Text(
          orexAppName,
          textAlign: textAlign,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontSize: titleFontSize,
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 6),
        Text(
          orexAppSlogan,
          textAlign: textAlign,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (showVersion) ...[
          const SizedBox(height: 10),
          Text(
            (version ?? OrexAppVersion.fallback).settingsSubtitle,
            textAlign: textAlign,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? OrexColors.cream.withValues(alpha: 0.82)
                      : OrexColors.walnutDeep.withValues(alpha: 0.72),
                  fontSize: 13,
                ),
          ),
        ],
      ],
    );
  }
}
