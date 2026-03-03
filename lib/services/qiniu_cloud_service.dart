import "dart:convert";
import "dart:typed_data";

import "package:crypto/crypto.dart";
import "package:http/http.dart" as http;
import "package:qiniu_flutter_sdk/qiniu_flutter_sdk.dart" as qiniu_flutter;
import "package:qiniu_sdk_base/qiniu_sdk_base.dart";

import "../models/qiniu_config.dart";

class QiniuConnectivityResult {
  const QiniuConnectivityResult({
    required this.bucket,
    required this.key,
    required this.fileName,
    required this.url,
    required this.expireAt,
  });

  final String bucket;
  final String key;
  final String fileName;
  final String url;
  final int expireAt;
}

class QiniuSyncResult {
  const QiniuSyncResult({
    required this.key,
    required this.fileName,
    required this.bucket,
    required this.url,
    required this.expireAt,
  });

  final String key;
  final String fileName;
  final String bucket;
  final String url;
  final int expireAt;
}

class QiniuPullResult {
  const QiniuPullResult({
    required this.key,
    required this.fileName,
    required this.url,
    required this.payload,
  });

  final String key;
  final String fileName;
  final String url;
  final Map<String, dynamic> payload;
}

class QiniuCloudService {
  QiniuCloudService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  QiniuConnectivityResult testConnectivityNoUpload({
    required QiniuConfig config,
    required String uin,
  }) {
    final _PreparedCloudTarget prepared = _prepareTarget(config, uin);
    final String token = _createUploadToken(prepared.config, prepared.key);
    if (token.isEmpty) {
      throw Exception("上传 token 生成失败");
    }
    final int expireAt = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300;
    final String privateUrl = _buildPrivateDownloadUrl(
      prepared.config,
      prepared.key,
      expireAt,
    );
    return QiniuConnectivityResult(
      bucket: prepared.config.bucket,
      key: prepared.key,
      fileName: prepared.fileName,
      url: privateUrl,
      expireAt: expireAt,
    );
  }

  Future<QiniuSyncResult> syncLocalStats({
    required QiniuConfig config,
    required String uin,
    required Map<String, dynamic> cloudPayload,
  }) async {
    final _PreparedCloudTarget prepared = _prepareTarget(config, uin);
    final int syncStamp = _toInt(cloudPayload["cloudSyncedAt"]);
    final String uploadFileName =
        _buildVersionedCloudFileName(uin, syncStamp > 0 ? syncStamp : null);
    final String uploadKey = _buildCloudObjectKey(prepared.config, uploadFileName);
    final String token = _createUploadToken(prepared.config, uploadKey);
    if (token.isEmpty) {
      throw Exception("上传 token 生成失败");
    }

    final Map<String, dynamic> uploadPayload = _toMutableStringMap(cloudPayload);
    uploadPayload["cloudObjectKey"] = uploadKey;
    final String fileBody =
        const JsonEncoder.withIndent("  ").convert(uploadPayload);
    final Uint8List bodyBytes = Uint8List.fromList(utf8.encode(fileBody));

    try {
      final qiniu_flutter.Storage storage = qiniu_flutter.Storage(
        config: qiniu_flutter.Config(),
      );
      await storage.putBytes(
        bodyBytes,
        token,
        options: PutOptions(
          key: uploadKey,
          forceBySingle: true,
          mimeType: "application/json",
        ),
      );
    } catch (error) {
      final String lower = error.toString().toLowerCase();
      if (lower.contains("app/accesskey is not found") ||
          (lower.contains("storageerrortype.response") &&
              lower.contains("612"))) {
        throw Exception(
          "七牛云上传失败: AccessKey 不存在或不可用（612）。请确认填写的是七牛 AK/SK（不是 openid/token），并在七牛控制台检查 AK 是否被禁用。",
        );
      }
      throw Exception("七牛云上传失败: $error");
    }
    await _pruneCloudObjects(
      config: prepared.config,
      uin: uin,
      keepCount: 2,
    );

    final int expireAt = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300;
    final String privateUrl = _buildPrivateDownloadUrl(
      prepared.config,
      uploadKey,
      expireAt,
    );
    return QiniuSyncResult(
      key: uploadKey,
      fileName: uploadFileName,
      bucket: prepared.config.bucket,
      url: privateUrl,
      expireAt: expireAt,
    );
  }

  Future<QiniuPullResult> pullLocalStats({
    required QiniuConfig config,
    required String uin,
  }) async {
    final _PreparedCloudTarget prepared = _prepareTarget(config, uin);
    final String resolvedKey = await _resolveLatestCloudKey(
      config: prepared.config,
      uin: uin,
      fallbackKey: prepared.key,
    );
    final String pullKey =
        resolvedKey.trim().isEmpty ? prepared.key : resolvedKey.trim();
    final String pullFileName = pullKey.contains("/")
        ? pullKey.split("/").last.trim()
        : pullKey.trim();
    final int expireAt = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300;
    final String privateUrl = _buildPrivateDownloadUrl(
      prepared.config,
      pullKey,
      expireAt,
      cacheBust: true,
      cacheBustTs: DateTime.now().millisecondsSinceEpoch,
    );
    final http.Response response = await _client.get(
      Uri.parse(privateUrl),
      headers: const <String, String>{
        "Accept": "application/json",
        "Cache-Control": "no-cache, no-store, max-age=0",
        "Pragma": "no-cache",
        "Expires": "0",
      },
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception("云拉取失败: HTTP ${response.statusCode}");
    }
    final dynamic decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw Exception("云端文件不是有效 JSON");
    }
    return QiniuPullResult(
      key: pullKey,
      fileName: pullFileName.isEmpty ? prepared.fileName : pullFileName,
      url: privateUrl,
      payload: _toMutableStringMap(decoded),
    );
  }

  _PreparedCloudTarget _prepareTarget(QiniuConfig input, String uin) {
    final QiniuConfig config = QiniuConfig.fromJson(input.toJson());
    if (!config.isReady) {
      throw Exception("请先完整填写七牛云配置（AccessKey/SecretKey/域名/Bucket）");
    }
    final String fileName = _buildLegacyCloudFileName(uin);
    final String key = _buildCloudObjectKey(config, fileName);
    return _PreparedCloudTarget(config: config, key: key, fileName: fileName);
  }

  String _buildCloudBaseName(String uin) {
    final String normalizedUin = uin.trim().isEmpty ? "unknown" : uin.trim();
    return "local-stats$normalizedUin-cloud";
  }

  String _buildLegacyCloudFileName(String uin) {
    return "${_buildCloudBaseName(uin)}.json";
  }

  String _buildVersionedCloudFileName(String uin, int? stampMs) {
    final int ts = stampMs != null && stampMs > 0
        ? stampMs
        : DateTime.now().millisecondsSinceEpoch;
    return "${_buildCloudBaseName(uin)}-$ts.json";
  }

  String _buildCloudObjectKey(QiniuConfig config, String fileName) {
    final String safeName = fileName.trim();
    if (safeName.isEmpty) return "";
    if (config.path.isEmpty) return safeName;
    return "${config.path}/$safeName";
  }

  String _buildQiniuFileUrl(QiniuConfig config, String key) {
    final String protocol =
        config.protocol.toLowerCase() == "http" ? "http" : "https";
    final String encodedKey = key
        .split("/")
        .map((String segment) => Uri.encodeComponent(segment))
        .join("/");
    return "$protocol://${config.domain}/$encodedKey";
  }

  String _buildPrivateDownloadUrl(
    QiniuConfig config,
    String key,
    int expireAt, {
    bool cacheBust = false,
    int cacheBustTs = 0,
  }) {
    final String publicUrl = _buildQiniuFileUrl(config, key);
    final StringBuffer signedUrl = StringBuffer(publicUrl);
    signedUrl.write(publicUrl.contains("?") ? "&" : "?");
    if (cacheBust) {
      final int ts = cacheBustTs > 0
          ? cacheBustTs
          : DateTime.now().millisecondsSinceEpoch;
      signedUrl.write("ts=$ts&");
    }
    signedUrl.write("e=$expireAt");
    final String signedUrlText = signedUrl.toString();
    final List<int> digestBytes = Hmac(sha1, utf8.encode(config.secretKey))
        .convert(utf8.encode(signedUrlText))
        .bytes;
    final String digest = _base64UrlSafeKeepPadding(digestBytes);
    return "$signedUrlText&token=${config.accessKey}:$digest";
  }

  String _createUploadToken(QiniuConfig config, String key) {
    final int deadline = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
    return _createUploadTokenWithPolicy(
      accessKey: config.accessKey,
      secretKey: config.secretKey,
      putPolicy: <String, dynamic>{
        "scope": "${config.bucket}:$key",
        "insertOnly": 0,
        "deadline": deadline,
      },
    );
  }

  String _createUploadTokenWithPolicy({
    required String accessKey,
    required String secretKey,
    required Map<String, dynamic> putPolicy,
  }) {
    final String scope = "${putPolicy["scope"] ?? ""}".trim();
    final int deadline = _toInt(putPolicy["deadline"]);
    if (scope.isEmpty || deadline <= 0) return "";
    final Auth auth = Auth(accessKey: accessKey, secretKey: secretKey);
    final PutPolicy policy = PutPolicy(
      scope: scope,
      deadline: deadline,
      insertOnly: _toInt(putPolicy["insertOnly"]),
    );
    return auth.generateUploadToken(putPolicy: policy);
  }

  Future<String> _resolveLatestCloudKey({
    required QiniuConfig config,
    required String uin,
    required String fallbackKey,
  }) async {
    final List<_CloudObjectItem> objects = await _listCloudObjects(
      config: config,
      uin: uin,
      limit: 100,
    );
    if (objects.isNotEmpty && objects.first.key.trim().isNotEmpty) {
      return objects.first.key.trim();
    }
    return fallbackKey;
  }

  bool _isCloudObjectKeyForUin({
    required String uin,
    required String key,
  }) {
    final String safeKey = key.trim();
    if (safeKey.isEmpty) return false;
    final String fileName = safeKey.contains("/")
        ? safeKey.split("/").last.trim()
        : safeKey;
    if (fileName.isEmpty) return false;
    final String base = _buildCloudBaseName(uin);
    final String legacy = _buildLegacyCloudFileName(uin);
    if (fileName == legacy) return true;
    return fileName.startsWith("$base-") && fileName.endsWith(".json");
  }

  Future<List<_CloudObjectItem>> _listCloudObjects({
    required QiniuConfig config,
    required String uin,
    int limit = 100,
  }) async {
    final String prefix = _buildCloudObjectKey(config, _buildCloudBaseName(uin));
    if (prefix.isEmpty) return const <_CloudObjectItem>[];
    final int safeLimit = limit < 1 ? 1 : (limit > 1000 ? 1000 : limit);
    final String pathWithQuery =
        "/list?bucket=${Uri.encodeQueryComponent(config.bucket)}"
        "&prefix=${Uri.encodeQueryComponent(prefix)}&limit=$safeLimit";
    final String token = _createManagementToken(
      accessKey: config.accessKey,
      secretKey: config.secretKey,
      pathWithQuery: pathWithQuery,
    );
    if (token.isEmpty) return const <_CloudObjectItem>[];
    try {
      final http.Response response = await _client.get(
        Uri.parse("https://rsf.qiniuapi.com$pathWithQuery"),
        headers: <String, String>{
          "Authorization": "QBox $token",
          "Accept": "application/json",
          "Cache-Control": "no-cache, no-store, max-age=0",
          "Pragma": "no-cache",
        },
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const <_CloudObjectItem>[];
      }
      final dynamic decoded = jsonDecode(response.body);
      if (decoded is! Map) return const <_CloudObjectItem>[];
      final dynamic itemsRaw = decoded["items"];
      if (itemsRaw is! List) return const <_CloudObjectItem>[];
      final List<_CloudObjectItem> out = <_CloudObjectItem>[];
      for (final dynamic item in itemsRaw) {
        if (item is! Map) continue;
        final String key = "${item["key"] ?? ""}".trim();
        if (!_isCloudObjectKeyForUin(uin: uin, key: key)) continue;
        out.add(
          _CloudObjectItem(
            key: key,
            putTime: _toInt(item["putTime"]),
          ),
        );
      }
      out.sort((_CloudObjectItem a, _CloudObjectItem b) {
        if (a.putTime != b.putTime) return b.putTime.compareTo(a.putTime);
        return b.key.compareTo(a.key);
      });
      return out;
    } catch (_) {
      return const <_CloudObjectItem>[];
    }
  }

  Future<void> _pruneCloudObjects({
    required QiniuConfig config,
    required String uin,
    required int keepCount,
  }) async {
    final int safeKeep = keepCount < 1 ? 1 : keepCount;
    final List<_CloudObjectItem> objects = await _listCloudObjects(
      config: config,
      uin: uin,
      limit: 1000,
    );
    if (objects.length <= safeKeep) return;
    final List<String> deleteKeys = objects
        .skip(safeKeep)
        .map((_CloudObjectItem item) => item.key)
        .where((String key) => _isCloudObjectKeyForUin(uin: uin, key: key))
        .where((String key) => key.trim().isNotEmpty)
        .toList();
    if (deleteKeys.isEmpty) return;
    final String body = deleteKeys
        .map((String key) =>
            "op=delete/${_encodeEntryUri(config.bucket, key)}")
        .join("&");
    if (body.trim().isEmpty) return;
    final String pathWithQuery = "/batch";
    final String token = _createManagementToken(
      accessKey: config.accessKey,
      secretKey: config.secretKey,
      pathWithQuery: pathWithQuery,
      body: body,
    );
    if (token.isEmpty) return;
    try {
      await _client.post(
        Uri.parse("https://rs.qiniuapi.com$pathWithQuery"),
        headers: <String, String>{
          "Authorization": "QBox $token",
          "Content-Type": "application/x-www-form-urlencoded",
          "Accept": "application/json",
        },
        body: body,
      );
    } catch (_) {
      // ignore prune failures to avoid blocking upload success
    }
  }

  String _encodeEntryUri(String bucket, String key) {
    final String raw = "${bucket.trim()}:${key.trim()}";
    return base64
        .encode(utf8.encode(raw))
        .replaceAll("+", "-")
        .replaceAll("/", "_")
        .replaceAll(RegExp(r"=+$"), "");
  }

  String _createManagementToken({
    required String accessKey,
    required String secretKey,
    required String pathWithQuery,
    String body = "",
  }) {
    final String safePath = pathWithQuery.trim();
    if (safePath.isEmpty) return "";
    final String signTarget = body.isEmpty ? "$safePath\n" : "$safePath\n$body";
    final List<int> digestBytes =
        Hmac(sha1, utf8.encode(secretKey)).convert(utf8.encode(signTarget)).bytes;
    final String digest = _base64UrlSafeKeepPadding(digestBytes);
    return "$accessKey:$digest";
  }

  String _base64UrlSafeKeepPadding(List<int> bytes) {
    return base64.encode(bytes).replaceAll("+", "-").replaceAll("/", "_");
  }

  Map<String, dynamic> _toMutableStringMap(dynamic value) {
    final Map<String, dynamic> out = <String, dynamic>{};
    if (value is Map) {
      value.forEach((dynamic key, dynamic item) {
        out["$key"] = item;
      });
    }
    return out;
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse("${value ?? ""}".trim()) ?? 0;
  }
}

class _PreparedCloudTarget {
  const _PreparedCloudTarget({
    required this.config,
    required this.key,
    required this.fileName,
  });

  final QiniuConfig config;
  final String key;
  final String fileName;
}

class _CloudObjectItem {
  const _CloudObjectItem({
    required this.key,
    required this.putTime,
  });

  final String key;
  final int putTime;
}

