import 'orex_web_picture_in_picture_stub.dart'
    if (dart.library.js_interop) 'orex_web_picture_in_picture_web.dart' as impl;

Future<bool> orexOpenWebPictureInPicture(
  String trackId, {
  String? preferredElementId,
  required void Function() onClosed,
}) => impl.orexOpenWebPictureInPicture(
  trackId,
  preferredElementId: preferredElementId,
  onClosed: onClosed,
);

Future<void> orexCloseWebPictureInPicture() =>
    impl.orexCloseWebPictureInPicture();
