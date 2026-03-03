import "dart:convert";

import "package:shared_preferences/shared_preferences.dart";

import "../models/qiniu_config.dart";

class QiniuConfigStore {
  static const String _qiniuConfigKey = "nzm_qiniu_config_v1";

  Future<QiniuConfig> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String raw = prefs.getString(_qiniuConfigKey) ?? "";
    if (raw.trim().isEmpty) {
      return QiniuConfig.empty();
    }
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return QiniuConfig.empty();
      }
      return QiniuConfig.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return QiniuConfig.empty();
    }
  }

  Future<QiniuConfig> save(QiniuConfig config) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final QiniuConfig normalized = QiniuConfig.fromJson(
      config
          .copyWith(updatedAt: DateTime.now().millisecondsSinceEpoch)
          .toJson(),
    );
    await prefs.setString(_qiniuConfigKey, jsonEncode(normalized.toJson()));
    return normalized;
  }
}
