class QiniuConfig {
  const QiniuConfig({
    required this.accessKey,
    required this.secretKey,
    required this.protocol,
    required this.domain,
    required this.path,
    required this.bucket,
    required this.updatedAt,
  });

  final String accessKey;
  final String secretKey;
  final String protocol;
  final String domain;
  final String path;
  final String bucket;
  final int updatedAt;

  factory QiniuConfig.empty() {
    return const QiniuConfig(
      accessKey: "",
      secretKey: "",
      protocol: "https",
      domain: "",
      path: "",
      bucket: "",
      updatedAt: 0,
    );
  }

  bool get isReady {
    return accessKey.isNotEmpty &&
        secretKey.isNotEmpty &&
        domain.isNotEmpty &&
        bucket.isNotEmpty;
  }

  QiniuConfig copyWith({
    String? accessKey,
    String? secretKey,
    String? protocol,
    String? domain,
    String? path,
    String? bucket,
    int? updatedAt,
  }) {
    return QiniuConfig(
      accessKey: accessKey ?? this.accessKey,
      secretKey: secretKey ?? this.secretKey,
      protocol: protocol ?? this.protocol,
      domain: domain ?? this.domain,
      path: path ?? this.path,
      bucket: bucket ?? this.bucket,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory QiniuConfig.fromJson(Map<String, dynamic> json) {
    final String protocolRaw =
        "${json["protocol"] ?? "https"}".trim().toLowerCase();
    return QiniuConfig(
      accessKey: _normalizeCredential("${json["accessKey"] ?? ""}"),
      secretKey: _normalizeCredential("${json["secretKey"] ?? ""}"),
      protocol: protocolRaw == "http" ? "http" : "https",
      domain: _normalizeDomain("${json["domain"] ?? ""}"),
      path: _normalizePath("${json["path"] ?? ""}"),
      bucket: "${json["bucket"] ?? ""}".trim(),
      updatedAt: _toInt(json["updatedAt"]),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      "accessKey": accessKey,
      "secretKey": secretKey,
      "protocol": protocol,
      "domain": _normalizeDomain(domain),
      "path": _normalizePath(path),
      "bucket": bucket,
      "updatedAt": updatedAt,
    };
  }

  static String _normalizeDomain(String input) {
    final String text = input.trim().replaceAll(RegExp(r"/+$"), "");
    return text.replaceFirst(RegExp(r"^https?://", caseSensitive: false), "");
  }

  static String _normalizePath(String input) {
    final String text = input.trim().replaceAll("\\", "/");
    return text.replaceAll(RegExp(r"^/+|/+$"), "");
  }

  static String _normalizeCredential(String input) {
    String text = input
        .replaceAll(RegExp(r"[\u0000-\u001F\u007F]"), "")
        .trim()
        .replaceAll(RegExp(r"\s+"), "");
    if (text.startsWith("\"") && text.endsWith("\"") && text.length > 1) {
      text = text.substring(1, text.length - 1).trim();
    }
    if (text.startsWith("'") && text.endsWith("'") && text.length > 1) {
      text = text.substring(1, text.length - 1).trim();
    }
    try {
      final String decoded = Uri.decodeComponent(text);
      if (decoded.trim().isNotEmpty) {
        text = decoded.trim().replaceAll(RegExp(r"\s+"), "");
      }
    } catch (_) {
      // Keep original when not URL-encoded.
    }
    return text;
  }

  static int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse("${value ?? ""}") ?? 0;
  }
}
