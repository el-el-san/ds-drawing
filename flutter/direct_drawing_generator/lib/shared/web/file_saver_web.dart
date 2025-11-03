// This file is only included on web builds via conditional imports.
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

Future<bool> triggerDownload({
  required String fileName,
  required List<int> bytes,
  String mimeType = 'application/octet-stream',
}) async {
  final html.Blob blob = html.Blob(<Object>[bytes], mimeType);
  final String url = html.Url.createObjectUrlFromBlob(blob);
  final html.AnchorElement anchor = html.AnchorElement(href: url)
    ..download = fileName
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);
  return true;
}
