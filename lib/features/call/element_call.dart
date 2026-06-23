// Запуск Element Call для комнаты.
//
// Element Call — это веб-приложение MatrixRTC поверх LiveKit (тот самый
// LiveKit + lk-jwt-service, что у вас развёрнут). Мы не тащим WebRTC в сам
// Flutter-клиент (это и давало лаги/зависания), а открываем готовый EC:
//   • Web    — встроенный <iframe> на отдельном экране.
//   • Native — системный браузер через url_launcher (надёжно везде, вкл. Windows).
//
// Полноценный «встроенный» звонок в native-приложении делается через webview +
// Matrix Widget API — это следующий шаг (см. README, раздел про звонки).
export 'element_call_io.dart'
    if (dart.library.js_interop) 'element_call_web.dart';
