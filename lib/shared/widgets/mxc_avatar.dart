import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/matrix/matrix_service.dart';
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
  Uri? _loadingMxc;

  @override
  void initState() {
    super.initState();
    final mxc = widget.mxc;
    if (mxc != null) _bytes = widget.matrix.cachedMxc(mxc);
    _load();
  }

  @override
  void didUpdateWidget(MxcAvatar old) {
    super.didUpdateWidget(old);
    if (old.mxc != widget.mxc) {
      final mxc = widget.mxc;
      _bytes = mxc == null ? null : widget.matrix.cachedMxc(mxc);
      _load();
    }
  }

  Future<void> _load() async {
    final mxc = widget.mxc;
    if (mxc == null) return;
    if (_loadingMxc == mxc) return;
    _loadingMxc = mxc;
    final cached = widget.matrix.cachedMxc(mxc);
    if (cached != null) {
      if (mounted && widget.mxc == mxc && !identical(cached, _bytes)) {
        setState(() => _bytes = cached);
      }
      _loadingMxc = null;
      return;
    }

    final data = await widget.matrix.downloadMxc(mxc);
    if (!mounted) return;
    if (_loadingMxc == mxc) _loadingMxc = null;
    if (widget.mxc != mxc) return;
    _loadingMxc = null;
    if (data != null && !identical(data, _bytes)) {
      setState(() => _bytes = data);
    }
  }

  @override
  Widget build(BuildContext context) {
    final initial =
        widget.name.isEmpty ? '?' : widget.name.characters.first.toUpperCase();
    return RepaintBoundary(
      child: Container(
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
      ),
    );
  }
}
