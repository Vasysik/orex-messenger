import 'dart:js_interop';

@JS('orexOpenPictureInPicture')
external JSPromise<JSBoolean> _orexOpenPictureInPicture(JSString trackId);

@JS('orexClosePictureInPicture')
external JSPromise<JSAny?> _orexClosePictureInPicture();

@JS('orexSetPictureInPictureClosedCallback')
external void _orexSetPictureInPictureClosedCallback(JSFunction callback);

Future<bool> orexOpenWebPictureInPicture(
  String trackId, {
  required void Function() onClosed,
}) async {
  _orexSetPictureInPictureClosedCallback((() => onClosed()).toJS);
  try {
    return (await _orexOpenPictureInPicture(trackId.toJS).toDart).toDart;
  } catch (_) {
    return false;
  }
}

Future<void> orexCloseWebPictureInPicture() async {
  try {
    await _orexClosePictureInPicture().toDart;
  } catch (_) {
    // The browser may have already closed PiP from its native chrome.
  }
}
