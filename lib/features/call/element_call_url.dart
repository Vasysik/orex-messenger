import '../../core/config.dart';

/// Строит URL комнаты Element Call.
///
/// ВНИМАНИЕ: точный набор query-параметров зависит от версии вашего Element
/// Call. Здесь — разумный дефолт; сверьте с вашим деплоем EC. Архитектура
/// (открыть EC для конкретной комнаты) от этого не меняется.
String buildElementCallUrl({
  required String roomId,
  bool video = true,
}) {
  final base = OrexConfig.elementCallBase;
  final params = {
    'roomId': roomId,
    'homeserver': OrexConfig.homeserverHost,
    'perParticipantE2EE': 'true',
    if (!video) 'video': 'false',
  };
  final query = params.entries
      .map((e) =>
          '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');
  // EC использует hash-роутинг.
  return '$base/room/#?$query';
}
