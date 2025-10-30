import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/mcp_config.dart';

enum _ContentTypeMode { json, jsonWithCharset }

/// MCP (Model Context Protocol) クライアント
/// k-os-ERI の HttpMcpClient と同様に initialize → notifications/initialized を実行し,
/// JSON-RPC 2.0 でツール呼び出しを行う。
class McpClient {
  McpClient(
    this.config, {
    http.Client? httpClient,
    void Function(String message)? logger,
  })  : _client = httpClient ?? http.Client(),
        _logger = logger ?? ((String message) => debugPrint(message));

  static const String _clientName = 'direct-drawing-generator';
  static const String _clientVersion = '1.0.0';
  static const Duration _defaultTimeout = Duration(seconds: 20);

  final McpConfig config;
  final http.Client _client;
  final void Function(String message) _logger;
  int _nextId = 1;
  String? _sessionId;
  bool _initialized = false;
  Future<void>? _initializing;

  Future<void> _ensureInitialized() async {
    if (_initialized) {
      return;
    }
    if (_initializing != null) {
      await _initializing;
      return;
    }
    _initializing = _initialize();
    try {
      await _initializing;
    } finally {
      _initializing = null;
    }
  }

  Future<void> _initialize() async {
    int attempts = 0;
    while (attempts < 2) {
      attempts++;
      try {
        final int id = _nextId++;
        final Map<String, dynamic> envelope = await _send(
          <String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'method': 'initialize',
            'params': <String, dynamic>{
              'protocolVersion': '2025-03-26',
              'capabilities': <String, dynamic>{},
              'clientInfo': <String, dynamic>{
                'name': _clientName,
                'version': _clientVersion,
              },
            },
          },
          expectedId: id,
        );
        _captureSessionFromBody(envelope['result'] as Map<String, dynamic>?);
        await _sendNotification('notifications/initialized');
        _initialized = true;
        return;
      } on Object catch (error) {
        if (attempts == 1 && _looksLikeInvalidSessionError(error)) {
          _sessionId = null;
          continue;
        }
        rethrow;
      }
    }
  }

  Future<void> _sendNotification(String method) async {
    final Map<String, dynamic> payload = <String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      'params': <String, dynamic>{},
    };

    try {
      final http.Response response =
          await _post(jsonEncode(payload), mode: _ContentTypeMode.json).timeout(_defaultTimeout);
      _captureSessionFromHeaders(response);
      if (!_isSuccessStatus(response.statusCode)) {
        _log('notifications/initialized HTTP ${response.statusCode} ${_truncate(response.body, 160)}');
      }
    } catch (error) {
      _log('notifications/initialized送信エラー: $error');
    }
  }

  Future<Map<String, dynamic>> callTool({
    required String toolName,
    required Map<String, dynamic> arguments,
  }) async {
    await _ensureInitialized();
    final Map<String, dynamic> envelope = await _callWithInvalidSessionRetry(
      'tools/call',
      <String, dynamic>{
        'name': toolName,
        'arguments': arguments,
      },
    );

    return envelope;
  }

  /// 画像生成リクエストを送信
  Future<String> submitGeneration({
    required String prompt,
    required List<String> imageUrls,
    int numImages = 1,
    Map<String, dynamic>? imageSize,
  }) async {
    final Map<String, dynamic> arguments = <String, dynamic>{
      'prompt': prompt,
      'image_urls': imageUrls,
      'num_images': numImages,
    };

    // imageSizeが指定されている場合は追加
    if (imageSize != null) {
      arguments['image_size'] = imageSize;
    }

    final Map<String, dynamic> response = await callTool(
      toolName: config.submitTool,
      arguments: arguments,
    );

    final Map<String, dynamic>? result = response['result'] as Map<String, dynamic>?;
    if (result == null) {
      throw Exception('レスポンスにresultフィールドがありません');
    }

    String? requestId = result['request_id'] as String?;
    requestId ??= result['requestId'] as String?;
    requestId ??= result['id'] as String?;

    if (requestId == null) {
      final List<dynamic>? content = result['content'] as List<dynamic>?;
      if (content != null && content.isNotEmpty) {
        final Map<String, dynamic>? firstContent = content[0] as Map<String, dynamic>?;
        if (firstContent != null && firstContent['type'] == 'text') {
          final String? text = firstContent['text'] as String?;
          if (text != null) {
            try {
              final Map<String, dynamic> parsedText = jsonDecode(text) as Map<String, dynamic>;
              requestId = parsedText['request_id'] as String?;
            } catch (_) {
              // Try multiple regex patterns
              final List<RegExp> patterns = <RegExp>[
                // Markdown format: **Request ID:** 94876f31-19d0-4e31-b628-29588e5da182
                RegExp(r'\*\*Request ID:\*\*\s+([a-f0-9\-]+)', caseSensitive: false),
                // JSON format: "request_id": "..."
                RegExp(r'"request_id"\s*:\s*"([^\"]+)"'),
                // Plain text format: Request ID: ...
                RegExp(r'Request ID:\s*([a-f0-9\-]+)', caseSensitive: false),
              ];

              for (final RegExp pattern in patterns) {
                final RegExpMatch? match = pattern.firstMatch(text);
                if (match != null) {
                  requestId = match.group(1);
                  break;
                }
              }
            }
          }
        }
      }
    }

    if (requestId == null || requestId.isEmpty) {
      throw Exception('request_idが取得できませんでした: ${jsonEncode(result)}');
    }

    return requestId;
  }

  Future<Map<String, dynamic>> checkStatus({required String requestId}) async {
    final Map<String, dynamic> response = await callTool(
      toolName: config.statusTool,
      arguments: <String, dynamic>{'request_id': requestId},
    );

    final Map<String, dynamic>? result = response['result'] as Map<String, dynamic>?;
    if (result == null) {
      throw Exception('ステータス確認のレスポンスが不正です');
    }

    return result;
  }

  Future<String> getResult({required String requestId}) async {
    final Map<String, dynamic> response = await callTool(
      toolName: config.resultTool,
      arguments: <String, dynamic>{'request_id': requestId},
    );

    final Map<String, dynamic>? result = response['result'] as Map<String, dynamic>?;
    if (result == null) {
      throw Exception('結果取得のレスポンスが不正です');
    }

    final String? imageUrl = _extractUrl(result);
    if (imageUrl == null || imageUrl.isEmpty) {
      throw Exception('画像URLが取得できませんでした: ${jsonEncode(result)}');
    }

    return imageUrl;
  }

  Future<String> pollUntilComplete({
    required String requestId,
    Duration pollInterval = const Duration(seconds: 5),
    int maxRetries = 20,
  }) async {
    const Set<String> successStates = <String>{
      'DONE',
      'COMPLETED',
      'SUCCESS',
      'SUCCEEDED',
      'FINISHED',
      'COMPLETED_SUCCESSFULLY',
    };
    const Set<String> failureStates = <String>{
      'ERROR',
      'FAILED',
      'FAILURE',
      'CANCELLED',
      'CANCELED',
      'TIMEOUT',
    };

    for (int i = 0; i < maxRetries; i++) {
      await Future<void>.delayed(pollInterval);
      final Map<String, dynamic> statusResponse = await checkStatus(requestId: requestId);

      String? state = _extractStatusFromResponse(statusResponse);

      _log('ポーリング ${i + 1}/$maxRetries: $state');

      if (state != null && successStates.contains(state)) {
        return getResult(requestId: requestId);
      }
      if (state != null && failureStates.contains(state)) {
        final String errorMsg = _extractErrorMessage(statusResponse) ?? 'Unknown error';
        throw Exception('生成に失敗しました: $errorMsg');
      }
    }

    throw Exception('生成がタイムアウトしました（最大 $maxRetries 回の再試行）');
  }

  Future<Map<String, dynamic>> _callWithInvalidSessionRetry(
    String method,
    Map<String, dynamic> params,
  ) async {
    try {
      return await _call(method, params);
    } on Object catch (error) {
      if (_looksLikeInvalidSessionError(error)) {
        _sessionId = null;
        _initialized = false;
        await _ensureInitialized();
        return _call(method, params);
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _call(String method, Map<String, dynamic> params) async {
    final int id = _nextId++;
    final Map<String, dynamic> payload = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    };

    _log('Request $method => ${jsonEncode(params)}');

    final Map<String, dynamic> envelope = await _send(payload, expectedId: id);
    final Map<String, dynamic>? result = envelope['result'] as Map<String, dynamic>?;
    _captureSessionFromBody(result);
    _log('Response ($method): ${jsonEncode(envelope)}');
    return envelope;
  }

  Future<Map<String, dynamic>> _send(
    Map<String, dynamic> payload, {
    required int expectedId,
  }) async {
    final String body = jsonEncode(payload);
    _ContentTypeMode mode = _ContentTypeMode.json;
    http.Response response = await _post(body, mode: mode).timeout(_defaultTimeout);
    _captureSessionFromHeaders(response);
    _log('HTTP status=${response.statusCode} body=${_truncate(response.body, 400)}');

    if (!_isSuccessStatus(response.statusCode)) {
      final String snippet = _truncate(response.body, 240);
      if (_looksLikeContentTypeError(response, snippet)) {
        final String lower = snippet.toLowerCase();
        final _ContentTypeMode nextMode =
            lower.contains('charset') ? _ContentTypeMode.jsonWithCharset : _ContentTypeMode.json;
        if (nextMode == mode) {
          throw Exception('HTTP ${response.statusCode} エラー: $snippet');
        }
        mode = nextMode;
        response = await _post(body, mode: mode).timeout(_defaultTimeout);
        _captureSessionFromHeaders(response);
        _log('HTTP retry status=${response.statusCode} body=${_truncate(response.body, 400)}');
        if (!_isSuccessStatus(response.statusCode)) {
          final String fallbackSnippet = _truncate(response.body, 240);
          throw Exception('HTTP ${response.statusCode} エラー: $fallbackSnippet');
        }
      } else {
        throw Exception('HTTP ${response.statusCode} エラー: $snippet');
      }
    }

    if (response.body.isEmpty) {
      throw Exception('レスポンスボディが空です');
    }

    if (!_isJsonContentType(response.headers['content-type'])) {
      final String snippet = _truncate(response.body, 240);
      throw Exception('JSONレスポンスではありません: $snippet');
    }

    Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(response.body) as Map<String, dynamic>;
    } on Object catch (error) {
      final String snippet = _truncate(response.body, 240);
      throw Exception('JSONパースに失敗しました: $error (body: $snippet)');
    }

    final dynamic responseIdRaw = envelope['id'];
    final int? responseId = _tryParseId(responseIdRaw);
    if (responseId != expectedId) {
      throw Exception('レスポンスIDが一致しません (expected=$expectedId actual=$responseIdRaw)');
    }

    if (envelope.containsKey('error')) {
      final Map<String, dynamic> error = envelope['error'] as Map<String, dynamic>;
      throw Exception('MCPエラー: ${error['message']}');
    }

    return envelope;
  }

  Future<http.Response> _post(
    String body, {
    _ContentTypeMode mode = _ContentTypeMode.json,
  }) async {
    final http.Request request = http.Request('POST', Uri.parse(config.url));
    request.headers.addAll(_buildHeaders(mode: mode));
    request.bodyBytes = utf8.encode(body);
    final http.StreamedResponse streamed = await _client.send(request);
    return http.Response.fromStream(streamed);
  }

  Map<String, String> _buildHeaders({
    _ContentTypeMode mode = _ContentTypeMode.json,
  }) {
    final Map<String, String> headers = <String, String>{
      'User-Agent': '$_clientName/$_clientVersion (Flutter)',
      'Connection': 'close',
      'Accept': 'application/json',
      'Content-Type': mode == _ContentTypeMode.jsonWithCharset
          ? 'application/json; charset=utf-8'
          : 'application/json',
    };

    if (_sessionId != null && _sessionId!.trim().isNotEmpty) {
      headers['mcp-session-id'] = _sessionId!.trim();
    }

    final String? auth = config.authorization;
    if (auth != null && auth.trim().isNotEmpty) {
      headers['Authorization'] = auth.trim();
    }

    return headers;
  }

  void _log(String message) {
    _logger('[MCP] $message');
  }

  void _captureSessionFromHeaders(http.Response response) {
    const List<String> headerKeys = <String>[
      'mcp-session-id',
      'mcp-session',
      'x-mcp-session-id',
      'x-session-id',
    ];

    for (final String key in headerKeys) {
      final String? value = response.headers[key];
      if (value != null && value.trim().isNotEmpty) {
        _sessionId = value.trim();
        return;
      }
    }
  }

  void _captureSessionFromBody(Map<String, dynamic>? body) {
    if (body == null) {
      return;
    }

    final List<String> candidates = <String>['sessionId', 'session_id'];
    for (final String key in candidates) {
      final dynamic value = body[key];
      if (value is String && value.trim().isNotEmpty) {
        _sessionId = value.trim();
        return;
      }
    }

    final Map<String, dynamic>? session = body['session'] as Map<String, dynamic>?;
    final String? nestedId = session?['id'] as String?;
    if (nestedId != null && nestedId.trim().isNotEmpty) {
      _sessionId = nestedId.trim();
      return;
    }

    final Map<String, dynamic>? serverInfo = body['serverInfo'] as Map<String, dynamic>?;
    final String? serverSession = serverInfo?['sessionId'] as String?;
    if (serverSession != null && serverSession.trim().isNotEmpty) {
      _sessionId = serverSession.trim();
    }
  }

  bool _isSuccessStatus(int statusCode) => statusCode >= 200 && statusCode < 300;

  bool _looksLikeContentTypeError(http.Response response, String snippet) {
    final String lower = snippet.toLowerCase();
    return response.statusCode >= 400 &&
        response.statusCode < 500 &&
        (lower.contains('invalid content type') || lower.contains('unsupported content type'));
  }

  bool _isJsonContentType(String? contentType) {
    if (contentType == null) {
      return false;
    }
    return contentType.toLowerCase().contains('application/json');
  }

  bool _looksLikeInvalidSessionError(Object error) {
    final String lower = error.toString().toLowerCase();
    return lower.contains('invalid') && lower.contains('session');
  }

  int? _tryParseId(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  String _truncate(String input, int maxLength) {
    if (input.length <= maxLength) {
      return input;
    }
    return '${input.substring(0, maxLength)}…';
  }

  /// MCPレスポンスからステータスを抽出
  String? _extractStatusFromResponse(Map<String, dynamic> data) {
    // 直接status/stateフィールドがある場合
    String? state = data['status'] as String?;
    state ??= data['state'] as String?;
    if (state != null) {
      return state.toUpperCase();
    }

    // content配列から抽出
    final List<dynamic>? content = data['content'] as List<dynamic>?;
    if (content != null && content.isNotEmpty) {
      for (final dynamic item in content) {
        if (item is Map<String, dynamic> && item['type'] == 'text') {
          final String? text = item['text'] as String?;
          if (text != null) {
            // **Status:** COMPLETED パターン
            final RegExp statusRegex = RegExp(r'\*\*Status:\*\*\s+(\w+)', caseSensitive: false);
            final RegExpMatch? match = statusRegex.firstMatch(text);
            if (match != null) {
              return match.group(1)?.toUpperCase();
            }
            // "status": "COMPLETED" パターン
            final RegExp jsonStatusRegex = RegExp(r'"status"\s*:\s*"(\w+)"', caseSensitive: false);
            final RegExpMatch? jsonMatch = jsonStatusRegex.firstMatch(text);
            if (jsonMatch != null) {
              return jsonMatch.group(1)?.toUpperCase();
            }
          }
        }
      }
    }

    return null;
  }

  /// MCPレスポンスからエラーメッセージを抽出
  String? _extractErrorMessage(Map<String, dynamic> data) {
    // 直接errorフィールドがある場合
    final dynamic error = data['error'];
    if (error is String) {
      return error;
    }
    if (error is Map<String, dynamic>) {
      return error['message'] as String? ?? error.toString();
    }

    // content配列から抽出
    final List<dynamic>? content = data['content'] as List<dynamic>?;
    if (content != null && content.isNotEmpty) {
      for (final dynamic item in content) {
        if (item is Map<String, dynamic> && item['type'] == 'text') {
          final String? text = item['text'] as String?;
          if (text != null) {
            // **Error:** ... パターン
            final RegExp errorRegex = RegExp(r'\*\*Error:\*\*\s+(.+)', caseSensitive: false);
            final RegExpMatch? match = errorRegex.firstMatch(text);
            if (match != null) {
              return match.group(1);
            }
            // **Message:** ... パターン
            final RegExp msgRegex = RegExp(r'\*\*Message:\*\*\s+(.+)', caseSensitive: false);
            final RegExpMatch? msgMatch = msgRegex.firstMatch(text);
            if (msgMatch != null) {
              return msgMatch.group(1);
            }
          }
        }
      }
    }

    return null;
  }

  /// レスポンスから画像URLを抽出する
  String? _extractUrl(Map<String, dynamic> data) {
    _log('URL抽出を開始: ${jsonEncode(data)}');

    if (data.containsKey('url')) {
      final String? url = data['url'] as String?;
      _log('data[\'url\']からURL発見: $url');
      return url;
    }
    if (data.containsKey('image_url')) {
      final String? url = data['image_url'] as String?;
      _log('data[\'image_url\']からURL発見: $url');
      return url;
    }
    if (data.containsKey('result_url')) {
      final String? url = data['result_url'] as String?;
      _log('data[\'result_url\']からURL発見: $url');
      return url;
    }

    final List<dynamic>? content = data['content'] as List<dynamic>?;
    if (content != null && content.isNotEmpty) {
      _log('content配列を探索中 (${content.length}アイテム)');
      for (final dynamic item in content) {
        if (item is Map<String, dynamic>) {
          if (item['type'] == 'text') {
            final String? text = item['text'] as String?;
            if (text != null) {
              _log('textタイプのコンテンツを発見: ${_truncate(text, 100)}');
              try {
                final Map<String, dynamic> parsed = jsonDecode(text) as Map<String, dynamic>;
                _log('テキストをJSONとしてパース成功');
                final String? url = _extractUrl(parsed);
                if (url != null) {
                  _log('パースしたJSONからURL発見: $url');
                  return url;
                }
              } catch (_) {
                _log('JSONパース失敗、正規表現でURL検索中');
                final RegExp urlRegex = RegExp(
                  r'https?://[^\s<>"{}|\\^`\[\]]+\.(?:png|jpg|jpeg|gif|webp)',
                  caseSensitive: false,
                );
                final RegExpMatch? match = urlRegex.firstMatch(text);
                if (match != null) {
                  final String? url = match.group(0);
                  _log('正規表現でURL発見: $url');
                  return url;
                }
                _log('正規表現でもURL発見できず');
              }
            }
          } else if (item['type'] == 'image') {
            final String? url = item['url'] as String?;
            if (url != null) {
              _log('imageタイプのコンテンツからURL発見: $url');
              return url;
            }
          }
        }
      }
    }

    final List<dynamic>? results = data['results'] as List<dynamic>?;
    if (results != null && results.isNotEmpty) {
      _log('results配列を探索中 (${results.length}アイテム)');
      final dynamic first = results[0];
      if (first is Map<String, dynamic>) {
        _log('results[0]をMap<String, dynamic>として再帰的に探索');
        return _extractUrl(first);
      } else if (first is String && first.startsWith('http')) {
        _log('results[0]からURL発見 (String): $first');
        return first;
      }
    }

    final List<dynamic>? images = data['images'] as List<dynamic>?;
    if (images != null && images.isNotEmpty) {
      _log('images配列を探索中 (${images.length}アイテム)');
      final dynamic first = images[0];
      if (first is Map<String, dynamic>) {
        final String? url = first['url'] as String?;
        if (url != null) {
          _log('images[0][\'url\']からURL発見: $url');
          return url;
        }
        _log('images[0]をMap<String, dynamic>として再帰的に探索');
        return _extractUrl(first);
      } else if (first is String && first.startsWith('http')) {
        _log('images[0]からURL発見 (String): $first');
        return first;
      }
    }

    _log('URL抽出失敗: どのパターンにも一致しませんでした');
    return null;
  }
}
