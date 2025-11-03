import 'dart:async';
import 'dart:convert';
import 'package:universal_io/io.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:path_provider/path_provider.dart';

import '../features/drawing/models/app_settings.dart';

const String _kDeviceIdKey = 'upload_device_id';

class UploadAuthToken {
  UploadAuthToken({
    required this.token,
    required this.expiresIn,
    required this.expiresAt,
    required this.deviceId,
    this.userId,
  });

  final String token;
  final int expiresIn;
  final DateTime expiresAt;
  final String deviceId;
  final String? userId;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class UploadAuthException implements Exception {
  UploadAuthException(this.message);
  final String message;

  @override
  String toString() => 'UploadAuthException: $message';
}

class UploadAuthManager {
  UploadAuthToken? _cachedToken;
  String? _cachedEndpoint;
  Future<UploadAuthToken>? _inFlight;
  String? _cachedTurnstileUrl;

  void invalidate() {
    _cachedToken = null;
    _cachedEndpoint = null;
    _cachedTurnstileUrl = null;
  }

  Future<UploadAuthToken> ensureJwt({
    required BuildContext context,
    required String vendingEndpoint,
    String? turnstileUrl,
    bool forceRefresh = false,
  }) async {
    final String trimmedEndpoint = vendingEndpoint.trim();
    if (trimmedEndpoint.isEmpty) {
      throw UploadAuthException('トークン発行エンドポイントが設定されていません。');
    }

    if (forceRefresh) {
      invalidate();
    }

    final String normalizedVerifyUrl = (turnstileUrl?.trim().isNotEmpty == true)
        ? turnstileUrl!.trim()
        : AppSettings.kEmbeddedTurnstileVerifyUrl;

    if (_cachedToken != null &&
        _cachedEndpoint == trimmedEndpoint &&
        _cachedTurnstileUrl == normalizedVerifyUrl &&
        !_cachedToken!.isExpired) {
      return _cachedToken!;
    }

    if (_inFlight != null) {
      return _inFlight!;
    }

    _inFlight = _fetchAndCacheToken(
      context: context,
      endpoint: trimmedEndpoint,
      turnstileUrl: normalizedVerifyUrl,
    );

    try {
      return await _inFlight!;
    } finally {
      _inFlight = null;
    }
  }

  Future<String> _getOrCreateDeviceId() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    String? id = prefs.getString(_kDeviceIdKey);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await prefs.setString(_kDeviceIdKey, id);
    }
    return id;
  }

  Future<String?> _obtainTurnstileToken({
    required Element hostElement,
    required NavigatorState navigator,
    required Uri url,
  }) async {
    if (!hostElement.mounted) {
      return null;
    }

    String? result;
    bool completed = false;
    final WebViewController controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'TokenChannel',
        onMessageReceived: (JavaScriptMessage message) {
          if (completed) {
            return;
          }
          completed = true;
          result = message.message;
          navigator.maybePop(result);
        },
      )
      ..loadRequest(url);

    await navigator.push<String>(
      PageRouteBuilder<String>(
        opaque: false,
        barrierDismissible: false,
        barrierColor: Colors.black.withOpacity(0.45),
        pageBuilder: (BuildContext routeContext, Animation<double> animation, Animation<double> secondary) {
          return FadeTransition(
            opacity: animation,
            child: _TurnstileInlineSheet(
              controller: controller,
              onCancel: () {
                if (completed) {
                  return;
                }
                completed = true;
                result = null;
                navigator.maybePop();
              },
            ),
          );
        },
      ),
    ).then((String? value) {
      if (!completed) {
        result = value;
        completed = true;
      }
    });

    return result;
  }

  Future<String?> _obtainTurnstileTokenWindows({required Uri url}) async {
    final bool available = await WebviewWindow.isWebviewAvailable();
    if (!available) {
      throw UploadAuthException(
        'WebView2 Runtime が見つかりません。Microsoft Edge または WebView2 をインストールしてください。',
      );
    }

    final Directory baseDir = await getApplicationSupportDirectory();
    final Directory dataDir = Directory(
      '${baseDir.path}${Platform.pathSeparator}turnstile_webview',
    );
    if (!await dataDir.exists()) {
      await dataDir.create(recursive: true);
    }

    final Webview webview = await WebviewWindow.create(
      configuration: CreateConfiguration(
        title: 'Cloudflare Turnstile 認証',
        titleBarTopPadding: 0,
        windowHeight: 640,
        windowWidth: 480,
        userDataFolderWindows: dataDir.path,
      ),
    );

    final Completer<String?> completer = Completer<String?>();
    bool completed = false;

    void complete(String? value) {
      if (completed) {
        return;
      }
      completed = true;
      completer.complete(value);
    }

    String? parseToken(String message) {
      if (message.isEmpty) {
        return null;
      }
      try {
        final dynamic decoded = jsonDecode(message);
        if (decoded is Map<String, dynamic>) {
          final String? channel = decoded['channel'] as String?;
          if (channel == 'TokenChannel') {
            final dynamic payload = decoded['message'] ?? decoded['data'];
            if (payload is String && payload.isNotEmpty) {
              return payload;
            }
          }
          if (decoded['token'] is String && (decoded['token'] as String).isNotEmpty) {
            return decoded['token'] as String;
          }
        }
      } catch (_) {
        // not JSON, fall back to raw string
        if (message.trim().isNotEmpty) {
          return message.trim();
        }
      }
      return null;
    }

    late final OnWebMessageReceivedCallback messageCallback;
    messageCallback = (String message) {
      debugPrint('Turnstile(WebView2) message: $message');
      final String? token = parseToken(message);
      if (token == null) {
        return;
      }
      final String normalized = token.trim();
      if (normalized.isEmpty) {
        return;
      }
      if (normalized == 'ERROR' || normalized == 'TIMEOUT' || normalized == 'CANCEL') {
        debugPrint('Turnstile(WebView2) status: $normalized (waiting for retry)');
        return;
      }
      try {
        webview.removeOnWebMessageReceivedCallback(messageCallback);
      } catch (_) {}
      complete(normalized);
      try {
        webview.close();
      } catch (_) {}
    };

    webview.addOnWebMessageReceivedCallback(messageCallback);

    unawaited(webview.onClose.then((_) {
      try {
        webview.removeOnWebMessageReceivedCallback(messageCallback);
      } catch (_) {}
      complete(null);
    }));

    webview.addScriptToExecuteOnDocumentCreated(r'''
      (function() {
        const postToken = (value) => {
          try {
            if (window.chrome && window.chrome.webview && window.chrome.webview.postMessage) {
              window.chrome.webview.postMessage(JSON.stringify({
                channel: 'TokenChannel',
                message: value
              }));
              return;
            }
          } catch (_) {}
          try {
            if (window.chrome && window.chrome.webview && window.chrome.webview.postMessage) {
              window.chrome.webview.postMessage(value);
            }
          } catch (_) {}
        };
        window.TokenChannel = {
          postMessage: function(message) {
            postToken(message);
          }
        };
        window.addEventListener('message', function(event) {
          if (!event) {
            return;
          }
          const data = event.data;
          if (typeof data === 'string') {
            if (data.startsWith('{')) {
              try {
                const parsed = JSON.parse(data);
                if (parsed && (parsed.token || parsed.turnstileToken)) {
                  postToken(parsed.token || parsed.turnstileToken);
                }
              } catch (_) {}
            }
          } else if (data && (data.token || data.turnstileToken)) {
            postToken(data.token || data.turnstileToken);
          }
        });
      })();
    ''');

    webview.launch(url.toString());

    return completer.future;
  }

  Future<_JwtResponse> _requestJwt(
    String endpoint,
    String deviceId,
    String turnstileResponse,
  ) async {
    final Uri? uri = Uri.tryParse(endpoint);
    if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) {
      throw UploadAuthException('トークン発行エンドポイントのURLが不正です。');
    }

    final http.MultipartRequest request = http.MultipartRequest('POST', uri)
      ..fields['device_id'] = deviceId
      ..fields['deviceId'] = deviceId
      ..fields['cf-turnstile-response'] = turnstileResponse;
    request.headers['x-device-id'] = deviceId;

    http.StreamedResponse streamed;
    try {
      streamed = await request.send();
    } catch (error) {
      throw UploadAuthException('自販機ワーカーへの接続に失敗しました: $error');
    }

    final String body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) {
      throw UploadAuthException('トークン取得に失敗しました: HTTP ${streamed.statusCode} $body');
    }

    try {
      final dynamic decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('レスポンスがJSONオブジェクトではありません');
      }
      final Map<String, dynamic> map = decoded;
      final String? token = (map['token'] ?? map['jwt']) as String?;
      if (token == null || token.isEmpty) {
        throw const FormatException('レスポンスにtokenが含まれていません');
      }
      final int expiresIn = ((map['expiresIn'] ?? map['expires_in']) as num?)?.toInt() ?? 600;
      final String? userId = (map['userId'] ?? map['user_id']) as String?;
      return _JwtResponse(token: token, expiresIn: expiresIn, userId: userId);
    } catch (error) {
      throw UploadAuthException('トークンの解析に失敗しました: $error');
    }
  }

  Future<UploadAuthToken> _fetchAndCacheToken({
    required BuildContext context,
    required String endpoint,
    required String turnstileUrl,
  }) async {
    final Uri? verifyUri = Uri.tryParse(turnstileUrl);
    if (verifyUri == null || verifyUri.scheme.isEmpty || verifyUri.host.isEmpty) {
      throw UploadAuthException('Turnstile認証ページのURLが不正です。');
    }

    String? turnstileResponse;
    if (Platform.isWindows) {
      turnstileResponse = await _obtainTurnstileTokenWindows(url: verifyUri);
    } else {
      final Element? element = context is Element ? context : null;
      if (element == null) {
        throw UploadAuthException('Turnstile認証が完了する前に画面が閉じられました。');
      }
      if (!element.mounted) {
        throw UploadAuthException('Turnstile認証が完了する前に画面が閉じられました。');
      }
      final NavigatorState navigator = Navigator.of(context, rootNavigator: true);
      turnstileResponse = await _obtainTurnstileToken(
        hostElement: element,
        navigator: navigator,
        url: verifyUri,
      );
      if (!element.mounted) {
        throw UploadAuthException('Turnstile認証が完了する前に画面が閉じられました。');
      }
    }
    if (turnstileResponse == null) {
      throw UploadAuthException('Turnstileがキャンセルされました。');
    }
    if (turnstileResponse == 'ERROR' || turnstileResponse == 'TIMEOUT') {
      throw UploadAuthException('Turnstile認証に失敗しました ($turnstileResponse)。');
    }

    final String deviceId = await _getOrCreateDeviceId();

    final _JwtResponse response = await _requestJwt(
      endpoint,
      deviceId,
      turnstileResponse,
    );
    final int expiresIn = response.expiresIn <= 0 ? 600 : response.expiresIn;
    final DateTime expiresAt = DateTime.now().add(Duration(
      seconds: expiresIn > 10 ? expiresIn - 5 : expiresIn,
    ));
    final UploadAuthToken token = UploadAuthToken(
      token: response.token,
      expiresIn: expiresIn,
      expiresAt: expiresAt,
      deviceId: deviceId,
      userId: response.userId,
    );
    _cachedToken = token;
    _cachedEndpoint = endpoint;
    _cachedTurnstileUrl = turnstileUrl;
    return token;
  }
}

class _JwtResponse {
  const _JwtResponse({
    required this.token,
    required this.expiresIn,
    this.userId,
  });

  final String token;
  final int expiresIn;
  final String? userId;
}

class _TurnstileInlineSheet extends StatelessWidget {
  const _TurnstileInlineSheet({
    required this.controller,
    required this.onCancel,
  });

  final WebViewController controller;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final Size screenSize = MediaQuery.of(context).size;
    final double width = math.min(screenSize.width - 32, 420);
    final double height = math.min(screenSize.height * 0.6, 360);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 24, left: 16, right: 16),
          child: Material(
            color: const Color(0xff0f141b),
            elevation: 10,
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: width,
              height: height,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: const BoxDecoration(
                      color: Color(0xff1b2430),
                      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                    ),
                    child: Row(
                      children: <Widget>[
                        const Icon(Icons.verified_user, color: Color(0xff4a9eff)),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            '認証が必要です',
                            style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
                          ),
                        ),
                        IconButton(
                          onPressed: onCancel,
                          icon: const Icon(Icons.close, color: Colors.white70),
                          tooltip: 'キャンセル',
                        ),
                      ],
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(
                      'Cloudflare Turnstileで認証を完了すると、アップロード処理が再開します。',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: WebViewWidget(controller: controller),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
