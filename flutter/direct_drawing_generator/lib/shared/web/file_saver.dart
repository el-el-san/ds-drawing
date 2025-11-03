import 'file_saver_stub.dart'
    if (dart.library.html) 'file_saver_web.dart' as impl;

Future<bool> triggerDownload({
  required String fileName,
  required List<int> bytes,
  String mimeType = 'application/octet-stream',
}) {
  return impl.triggerDownload(fileName: fileName, bytes: bytes, mimeType: mimeType);
}
