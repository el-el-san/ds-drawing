import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

// 画像アップロードサービス
// 画像をサーバーにアップロードし、公開URLを取得します
class ImageUploadService {
  ImageUploadService({
    required this.uploadEndpoint,
    required this.exposeEndpoint,
    String? authorization,
    String? deviceId,
    this.logger,
  })  : _authorization = authorization,
        _deviceId = deviceId;

  // アップロードエンドポイント
  final String uploadEndpoint;

  /// 公開エンドポイント（フォールバック用）
  final String exposeEndpoint;

  /// 共通Authorizationヘッダー
  String? get authorization => _authorization;
  set authorization(String? value) => _authorization = value?.trim().isEmpty == true ? null : value;
  String? _authorization;

  /// アップロード時に付与するデバイスID
  String? get deviceId => _deviceId;
  set deviceId(String? value) => _deviceId = value?.trim().isEmpty == true ? null : value;
  String? _deviceId;

  /// ログ出力用コールバック
  final void Function(String)? logger;

  /// 画像をアップロードして公開URLを取得
  Future<String> uploadImage(Uint8List imageBytes, {String? filename}) async {
    final String mimeType = _detectMimeType(imageBytes);
    final String resolvedFilename = filename ?? _buildFilename(mimeType);
    final String dataUrl = _encodeAsDataUrl(imageBytes, mimeType);

    final String trimmedUploadEndpoint = uploadEndpoint.trim();
    final String trimmedExposeEndpoint = exposeEndpoint.trim();
    final bool hasUploadEndpoint = trimmedUploadEndpoint.isNotEmpty;
    final bool hasExposeEndpoint = trimmedExposeEndpoint.isNotEmpty;
    final bool expectsAuthorized = _authorization != null && _authorization!.isNotEmpty;

    if (!hasUploadEndpoint && !hasExposeEndpoint) {
      throw Exception('アップロードエンドポイントが未設定です。');
    }

    // 順番に複数のストラテジーを試す
    final List<Future<String> Function()> strategies = <Future<String> Function()>[];
    final List<String> strategyNames = <String>[];

    if (hasUploadEndpoint) {
      strategies.add(() => _tryMultipartUpload(imageBytes, resolvedFilename, mimeType));
      strategyNames.add('multipart');
      strategies.add(() => _tryJsonDataUpload(dataUrl, resolvedFilename, mimeType));
      strategyNames.add('JSON data URL');
    }

    // 認証付き設定の場合は旧exposeにはフォールバックしない
    if (!expectsAuthorized && hasExposeEndpoint) {
      strategies.add(() => _tryExpose(dataUrl, resolvedFilename, mimeType));
      strategyNames.add('expose');
    }

    if (strategies.isEmpty) {
      throw Exception('認証付きアップロードには uploadEndpoint が必要です。');
    }

    Exception? lastError;
    final List<String> failureSummaries = <String>[];

    for (int i = 0; i < strategies.length; i++) {
      final Future<String> Function() attempt = strategies[i];
      final String strategyName = strategyNames[i];
      try {
        _log('アップロード試行中: $strategyName');
        final String url = await attempt();
        final String normalized = _normalizePublicUrl(url);
        if (normalized != url) {
          _log('公開URLを正規化: $url -> $normalized');
        }
        _log('アップロード成功: $strategyName');
        return normalized;
      } on Object catch (error, stackTrace) {
        lastError = error is Exception ? error : Exception('$error');
        final String summary = '$strategyName失敗: $error';
        failureSummaries.add(summary);
        _log(summary);
        _log('$strategyName stack: $stackTrace');
      }
    }

    final String detail = failureSummaries.isEmpty
        ? '${lastError ?? 'unknown error'}'
        : failureSummaries.join(' / ');
    throw Exception('画像のアップロードに失敗しました: $detail');
  }

  /// /uploadエンドポイントを multipart/form-data で使用
  Future<String> _tryMultipartUpload(Uint8List imageBytes, String filename, String mimeType) async {
    final http.MultipartRequest request = http.MultipartRequest(
      'POST',
      Uri.parse(uploadEndpoint),
    );

    if (_authorization != null && _authorization!.isNotEmpty) {
      request.headers['Authorization'] = _normalizeAuthHeader(_authorization!);
    }
    request.headers['Accept'] = 'application/json';
    if (_deviceId != null && _deviceId!.isNotEmpty) {
      request.headers['X-Device-Id'] = _deviceId!;
    }

    request.files.add(
      http.MultipartFile.fromBytes(
        'media',
        imageBytes,
        filename: filename,
        contentType: MediaType.parse(mimeType),
      ),
    );

    final http.StreamedResponse response = await request.send();
    final String body = await response.stream.bytesToString();

    if (response.statusCode != 200) {
      throw Exception('アップロード失敗: ${response.statusCode} $body');
    }

    final String? url = _extractUrlFromResponse(body);
    if (url == null) {
      throw Exception('レスポンスにURLが含まれていません: $body');
    }

    debugPrint('画像アップロード成功 (/upload multipart): $url');
    return url;
  }

  /// /upload エンドポイントへ data URL を JSON で送信
  Future<String> _tryJsonDataUpload(String dataUrl, String filename, String mimeType) async {
    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
      if (_authorization != null && _authorization!.isNotEmpty) 'Authorization': _normalizeAuthHeader(_authorization!),
      if (_deviceId != null && _deviceId!.isNotEmpty) 'X-Device-Id': _deviceId!,
    };

    _log('JSON data URLアップロード: endpoint=$uploadEndpoint, filename=$filename, mimeType=$mimeType');

    final http.Response response = await http.post(
      Uri.parse(uploadEndpoint),
      headers: <String, String>{
        ...headers,
      },
      body: jsonEncode(<String, dynamic>{
        'url': dataUrl,
        'filename': filename,
        'mimetype': mimeType,
      }),
    );

    _log('JSON data URLレスポンス: status=${response.statusCode}, body=${response.body.substring(0, response.body.length > 200 ? 200 : response.body.length)}');

    if (response.statusCode != 200) {
      throw Exception('JSONアップロード失敗: ${response.statusCode} ${response.body}');
    }

    final String? url = _extractUrlFromResponse(response.body);
    if (url == null) {
      throw Exception('レスポンスにURLが含まれていません: ${response.body}');
    }

    _log('画像アップロード成功 (/upload data-url): $url');
    return url;
  }

  /// /exposeエンドポイントを使用（フォールバック）
  Future<String> _tryExpose(String dataUrl, String filename, String mimeType) async {
    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
      if (_authorization != null && _authorization!.isNotEmpty) 'Authorization': _normalizeAuthHeader(_authorization!),
      if (_deviceId != null && _deviceId!.isNotEmpty) 'X-Device-Id': _deviceId!,
    };

    final http.Response response = await http.post(
      Uri.parse(exposeEndpoint),
      headers: headers,
      body: jsonEncode(<String, dynamic>{
        'url': dataUrl,
        'filename': filename,
        'mimetype': mimeType,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('公開失敗: ${response.statusCode} ${response.body}');
    }

    final String? url = _extractUrlFromResponse(response.body);
    if (url == null) {
      throw Exception('レスポンスにURLが含まれていません: ${response.body}');
    }

    debugPrint('画像公開成功 (/expose data-url): $url');
    return url;
  }

  /// 複数の画像をアップロード
  Future<List<String>> uploadMultiple(List<Uint8List> imageBytesList) async {
    final List<String> urls = <String>[];

    for (int i = 0; i < imageBytesList.length; i++) {
      final String url = await uploadImage(
        imageBytesList[i],
        filename: 'drawing_${DateTime.now().millisecondsSinceEpoch}_$i.png',
      );
      urls.add(url);
    }

    return urls;
  }

  String _detectMimeType(Uint8List bytes) {
    if (bytes.length >= 4) {
      if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4e && bytes[3] == 0x47) {
        return 'image/png';
      }
      if (bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) {
        return 'image/jpeg';
      }
      if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) {
        return 'image/gif';
      }
      if (bytes.length >= 12 &&
          bytes[0] == 0x52 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46 &&
          bytes[3] == 0x46 &&
          bytes[8] == 0x57 &&
          bytes[9] == 0x45 &&
          bytes[10] == 0x42 &&
          bytes[11] == 0x50) {
        return 'image/webp';
      }
      if (bytes[0] == 0x42 && bytes[1] == 0x4d) {
        return 'image/bmp';
      }
      if ((bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2a && bytes[3] == 0x00) ||
          (bytes[0] == 0x4d && bytes[1] == 0x4d && bytes[2] == 0x00 && bytes[3] == 0x2a)) {
        return 'image/tiff';
      }
      if (bytes.length >= 12 &&
          bytes[4] == 0x66 &&
          bytes[5] == 0x74 &&
          bytes[6] == 0x79 &&
          bytes[7] == 0x70) {
        // HEIC/HEIF/MP4 family — treat as HEIC by default
        return 'image/heic';
      }
    }
    return 'image/png';
  }

  String _buildFilename(String mimeType) {
    final String extension = _extensionFromMime(mimeType);
    return 'drawing_${DateTime.now().millisecondsSinceEpoch}.$extension';
  }

  String _extensionFromMime(String mimeType) {
    switch (mimeType) {
      case 'image/png':
        return 'png';
      case 'image/jpeg':
        return 'jpg';
      case 'image/gif':
        return 'gif';
      case 'image/webp':
        return 'webp';
      case 'image/bmp':
        return 'bmp';
      case 'image/tiff':
        return 'tiff';
      case 'image/heic':
        return 'heic';
      default:
        return 'bin';
    }
  }

  String _encodeAsDataUrl(Uint8List bytes, String mimeType) {
    final String base64Data = base64Encode(bytes);
    return 'data:$mimeType;base64,$base64Data';
  }

  String _normalizePublicUrl(String url) {
    return url.replaceAllMapped(
      RegExp(r'%(?!25)([0-9A-Fa-f]{2})'),
      (Match match) => '%25${match.group(1)}',
    );
  }

  String? _extractUrlFromResponse(String body) {
    try {
      final dynamic decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final Map<String, dynamic> map = decoded;
        final List<String?> candidates = <String?>[
          map['uploaded_url'] as String?,
          map['public_url'] as String?,
          map['url'] as String?,
          map['file_url'] as String?,
          map['data'] is Map<String, dynamic> ? (map['data'] as Map<String, dynamic>)['url'] as String? : null,
          map['result'] is Map<String, dynamic> ? (map['result'] as Map<String, dynamic>)['url'] as String? : null,
        ];
        for (final String? candidate in candidates) {
          if (candidate != null && candidate.isNotEmpty) {
            return candidate;
          }
        }
      }
      if (decoded is String && decoded.isNotEmpty) {
        return decoded;
      }
    } catch (_) {
      // JSON decode failure falls back to regex
    }

    final Iterable<String> segments = body.split(RegExp(r'\s+'));
    for (final String segment in segments) {
      if (segment.startsWith('http://') || segment.startsWith('https://')) {
        String url = segment;
        while (url.isNotEmpty && (url.endsWith('"') || url.endsWith("'") || url.endsWith(',') || url.endsWith(';'))) {
          url = url.substring(0, url.length - 1);
        }
        if (url.isNotEmpty) {
          return url;
        }
      }
    }
    return null;
  }

  /// Authorizationヘッダーを正規化
  /// ユーザーが "Bearer " プレフィックスを含めていない場合は自動的に追加
  String _normalizeAuthHeader(String auth) {
    final String trimmed = auth.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }
    // 既に "Bearer " で始まっている場合はそのまま返す
    if (trimmed.toLowerCase().startsWith('bearer ')) {
      return trimmed;
    }
    // それ以外の場合は "Bearer " を追加
    return 'Bearer $trimmed';
  }

  /// ログ出力（loggerが設定されていればそれを使用、なければdebugPrint）
  void _log(String message) {
    if (logger != null) {
      logger!(message);
    } else {
      debugPrint(message);
    }
  }
}
