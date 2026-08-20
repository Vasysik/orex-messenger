import 'package:web/web.dart' as web;

const bool orexDownloadPageAvailable = true;

void openOrexDownloadPage() {
  web.window.open('/download/', '_blank', 'noopener,noreferrer');
}

void openOrexDownloadArtifact(Uri uri) {
  web.window.location.assign(uri.toString());
}
