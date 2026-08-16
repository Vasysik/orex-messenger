import 'package:web/web.dart' as web;

const bool orexDownloadPageAvailable = true;

void openOrexDownloadPage() {
  web.window.location.assign('/download/');
}

void openOrexDownloadArtifact(Uri uri) {
  web.window.location.assign(uri.toString());
}
