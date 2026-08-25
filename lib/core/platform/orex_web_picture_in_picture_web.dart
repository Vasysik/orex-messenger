import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('orexOpenPictureInPicture')
external JSPromise<JSBoolean> _orexOpenPictureInPicture(
  JSString trackId,
  JSString? preferredElementId,
);

@JS('orexClosePictureInPicture')
external JSPromise<JSAny?> _orexClosePictureInPicture();

@JS('orexSetPictureInPictureClosedCallback')
external void _orexSetPictureInPictureClosedCallback(JSFunction callback);

bool get _orexPictureInPictureBridgeAvailable =>
    globalContext.has('orexOpenPictureInPicture') &&
    globalContext.has('orexClosePictureInPicture') &&
    globalContext.has('orexSetPictureInPictureClosedCallback');

Future<bool> orexOpenWebPictureInPicture(
  String trackId, {
  String? preferredElementId,
  required void Function() onClosed,
}) async {
  if (!_orexPictureInPictureBridgeAvailable) return false;
  try {
    _orexSetPictureInPictureClosedCallback((() => onClosed()).toJS);
    return (await _orexOpenPictureInPicture(
      trackId.toJS,
      preferredElementId?.toJS,
    ).toDart).toDart;
  } catch (_) {
    return false;
  }
}

Future<void> orexCloseWebPictureInPicture() async {
  if (!globalContext.has('orexClosePictureInPicture')) return;
  try {
    await _orexClosePictureInPicture().toDart;
  } catch (_) {
    // The browser may have already closed PiP from its native chrome.
  }
}
