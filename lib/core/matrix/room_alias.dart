import 'package:matrix/matrix.dart';

final class OrexRoomAlias {
  const OrexRoomAlias._();

  static String? normalizeLocalpart(String? alias) {
    var value = alias?.trim() ?? '';
    if (value.isEmpty) return null;
    if (value.startsWith('#')) value = value.substring(1);
    if (value.contains(':')) value = value.split(':').first;
    value = value
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'[^a-z0-9._=-]'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return value.isEmpty ? null : value;
  }

  static String? fullAlias(String? localAlias, String? serverName) {
    final localpart = normalizeLocalpart(localAlias);
    if (localpart == null || serverName == null || serverName.isEmpty) {
      return null;
    }
    return '#$localpart:$serverName';
  }

  static String localpartFromRoom(Room room) {
    final alias = room.canonicalAlias;
    if (!alias.startsWith('#')) return '';
    return alias.substring(1).split(':').first;
  }
}
