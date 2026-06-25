import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/matrix_service.dart';
import '../theme/orex_theme.dart';

/// Круглый аватар. Если есть mxc-ссылка — качает байты через
/// аутентифицированный эндпоинт (иначе на новых Synapse будет 404),
/// иначе показывает инициал на медном градиенте.
class MxcAvatar extends StatefulWidget {
  const MxcAvatar({
    super.key,
    required this.matrix,
    required this.name,
    this.mxc,
    this.size = 48,
  });

  final MatrixService matrix;
  final String name;
  final Uri? mxc;
  final double size;

  @override
  State<MxcAvatar> createState() => _MxcAvatarState();
}

class _MxcAvatarState extends State<MxcAvatar> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
    // Реагируем на sync/обновление профилей: если у человека сменился аватар
    // (новый mxc) или сбросился кэш — подтянем картинку без перезагрузки.
    widget.matrix.addListener(_onMatrix);
  }

  void _onMatrix() => _load();

  @override
  void didUpdateWidget(MxcAvatar old) {
    super.didUpdateWidget(old);
    if (old.mxc != widget.mxc) {
      _bytes = null;
      _load();
    }
  }

  @override
  void dispose() {
    widget.matrix.removeListener(_onMatrix);
    super.dispose();
  }

  Future<void> _load() async {
    final mxc = widget.mxc;
    if (mxc == null) return;
    final data = await widget.matrix.downloadMxc(mxc);
    // identical-проверка: кэш отдаёт ту же ссылку для неизменных аватаров —
    // тогда не дёргаем setState (иначе перерисовка на каждый sync).
    if (mounted && data != null && !identical(data, _bytes)) {
      setState(() => _bytes = data);
    }
  }

  @override
  Widget build(BuildContext context) {
    final initial = widget.name.isEmpty
        ? '?'
        : widget.name.characters.first.toUpperCase();
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: _bytes == null ? OrexColors.copperGradient : null,
        image: _bytes != null
            ? DecorationImage(image: MemoryImage(_bytes!), fit: BoxFit.cover)
            : null,
      ),
      alignment: Alignment.center,
      child: _bytes == null
          ? Text(
              initial,
              style: TextStyle(
                color: OrexColors.cream,
                fontWeight: FontWeight.w700,
                fontSize: widget.size * 0.4,
              ),
            )
          : null,
    );
  }
}
