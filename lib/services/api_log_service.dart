import "dart:convert";

import "package:flutter/foundation.dart";

enum ApiLogType { request, response }

class ApiLogEntry {
  const ApiLogEntry({
    required this.id,
    required this.type,
    required this.timestamp,
    required this.method,
    required this.url,
    this.statusCode,
    required this.headersText,
    required this.bodyText,
  });

  final int id;
  final ApiLogType type;
  final DateTime timestamp;
  final String method;
  final String url;
  final int? statusCode;
  final String headersText;
  final String bodyText;

  String get typeLabel => type == ApiLogType.request ? "REQ" : "RES";

  String get timeText {
    String two(int value) => value.toString().padLeft(2, "0");
    final DateTime t = timestamp;
    return "${two(t.hour)}:${two(t.minute)}:${two(t.second)}";
  }
}

class ApiLogService extends ChangeNotifier {
  ApiLogService._();

  static final ApiLogService instance = ApiLogService._();
  static const int _maxEntries = 300;

  final List<ApiLogEntry> _entries = <ApiLogEntry>[];
  int _nextId = 1;

  List<ApiLogEntry> get entries => List<ApiLogEntry>.unmodifiable(_entries);

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }

  void addRequest({
    required String method,
    required String url,
    Map<String, String>? headers,
    Object? body,
  }) {
    _addEntry(
      type: ApiLogType.request,
      method: method,
      url: url,
      statusCode: null,
      headersText: _formatPayload(headers),
      bodyText: _formatPayload(body),
    );
  }

  void addResponse({
    required String method,
    required String url,
    required int statusCode,
    Map<String, String>? headers,
    Object? body,
  }) {
    _addEntry(
      type: ApiLogType.response,
      method: method,
      url: url,
      statusCode: statusCode,
      headersText: _formatPayload(headers),
      bodyText: _formatPayload(body),
    );
  }

  void _addEntry({
    required ApiLogType type,
    required String method,
    required String url,
    required int? statusCode,
    required String headersText,
    required String bodyText,
  }) {
    _entries.insert(
      0,
      ApiLogEntry(
        id: _nextId++,
        type: type,
        timestamp: DateTime.now(),
        method: method.toUpperCase(),
        url: url,
        statusCode: statusCode,
        headersText: _truncate(headersText),
        bodyText: _truncate(bodyText),
      ),
    );
    if (_entries.length > _maxEntries) {
      _entries.removeRange(_maxEntries, _entries.length);
    }
    notifyListeners();
  }

  String _formatPayload(Object? payload) {
    if (payload == null) return "";
    if (payload is String) return _formatStringPayload(payload);
    if (payload is Map || payload is List) {
      return _prettyJson(_normalizeDynamic(payload));
    }
    return _truncate(payload.toString());
  }

  String _formatStringPayload(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return "";

    final dynamic decoded = _tryJsonDecode(text);
    if (decoded is Map || decoded is List) {
      return _prettyJson(_normalizeDynamic(decoded));
    }

    try {
      final Map<String, String> query = Uri.splitQueryString(text);
      if (query.isNotEmpty) {
        final Map<String, dynamic> normalized = <String, dynamic>{};
        for (final MapEntry<String, String> e in query.entries) {
          normalized[e.key] = _normalizeStringValue(e.value);
        }
        return _prettyJson(normalized);
      }
    } catch (_) {
      // Keep raw text when not a query string.
    }

    return _truncate(text);
  }

  dynamic _normalizeDynamic(dynamic value) {
    if (value is Map) {
      final Map<String, dynamic> output = <String, dynamic>{};
      value.forEach((dynamic key, dynamic item) {
        output["$key"] = _normalizeDynamic(item);
      });
      return output;
    }
    if (value is List) {
      return value.map<dynamic>(_normalizeDynamic).toList();
    }
    if (value is String) {
      return _normalizeStringValue(value);
    }
    return value;
  }

  dynamic _normalizeStringValue(String value) {
    final String text = value.trim();
    if (text.isEmpty) return "";
    final dynamic decoded = _tryJsonDecode(text);
    if (decoded is Map || decoded is List) {
      return _normalizeDynamic(decoded);
    }
    return text;
  }

  dynamic _tryJsonDecode(String text) {
    final String t = text.trim();
    if (t.isEmpty) return null;
    final bool looksLikeJson = t.startsWith("{") ||
        t.startsWith("[") ||
        t == "null" ||
        t == "true" ||
        t == "false" ||
        RegExp(r"^-?\d+(\.\d+)?$").hasMatch(t);
    if (!looksLikeJson) return null;
    try {
      return jsonDecode(t);
    } catch (_) {
      return null;
    }
  }

  String _prettyJson(Object value) {
    try {
      return const JsonEncoder.withIndent("  ").convert(value);
    } catch (_) {
      return _truncate(value.toString());
    }
  }

  String _truncate(String text, {int max = 200000}) {
    final String t = text.trim();
    if (t.length <= max) return t;
    return "${t.substring(0, max)}...(truncated)";
  }
}
