class AccountBinding {
  const AccountBinding({
    required this.uin,
    required this.openid,
    required this.accessToken,
    required this.nickname,
    required this.avatar,
    required this.updatedAt,
  });

  final String uin;
  final String openid;
  final String accessToken;
  final String nickname;
  final String avatar;
  final int updatedAt;

  String get displayName {
    if (nickname.trim().isNotEmpty) {
      return nickname.trim();
    }
    if (uin.trim().isNotEmpty) {
      return uin.trim();
    }
    return "未命名账号";
  }

  AccountBinding copyWith({
    String? uin,
    String? openid,
    String? accessToken,
    String? nickname,
    String? avatar,
    int? updatedAt,
  }) {
    return AccountBinding(
      uin: uin ?? this.uin,
      openid: openid ?? this.openid,
      accessToken: accessToken ?? this.accessToken,
      nickname: nickname ?? this.nickname,
      avatar: avatar ?? this.avatar,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory AccountBinding.fromJson(Map<String, dynamic> json) {
    return AccountBinding(
      uin: "${json["uin"] ?? ""}".trim(),
      openid: "${json["openid"] ?? ""}".trim(),
      accessToken: "${json["accessToken"] ?? ""}".trim(),
      nickname: "${json["nickname"] ?? ""}".trim(),
      avatar: "${json["avatar"] ?? ""}".trim(),
      updatedAt: _toInt(json["updatedAt"]),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      "uin": uin,
      "openid": openid,
      "accessToken": accessToken,
      "nickname": nickname,
      "avatar": avatar,
      "updatedAt": updatedAt,
    };
  }

  static int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse("${value ?? ""}") ?? 0;
  }
}
