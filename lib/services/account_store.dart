import "dart:convert";

import "package:shared_preferences/shared_preferences.dart";

import "../models/account_binding.dart";

class AccountStoreSnapshot {
  const AccountStoreSnapshot({required this.accounts, required this.activeUin});

  final List<AccountBinding> accounts;
  final String activeUin;
}

class AccountStore {
  static const String _accountsKey = "nzm_accounts_v1";
  static const String _activeUinKey = "nzm_active_uin_v1";

  Future<AccountStoreSnapshot> load() async {
    final prefs = await SharedPreferences.getInstance();
    final rawAccounts = prefs.getString(_accountsKey);
    final rawActiveUin = prefs.getString(_activeUinKey) ?? "";

    if (rawAccounts == null || rawAccounts.trim().isEmpty) {
      return AccountStoreSnapshot(
        accounts: const <AccountBinding>[],
        activeUin: "",
      );
    }

    try {
      final dynamic decoded = jsonDecode(rawAccounts);
      if (decoded is! List) {
        return AccountStoreSnapshot(
          accounts: const <AccountBinding>[],
          activeUin: "",
        );
      }
      final List<AccountBinding> accounts = decoded
          .whereType<Map>()
          .map((Map item) {
            final Map<String, dynamic> normalized = <String, dynamic>{};
            item.forEach((dynamic key, dynamic value) {
              normalized["${key ?? ""}"] = value;
            });
            return AccountBinding.fromJson(normalized);
          })
          .toList();
      return AccountStoreSnapshot(accounts: accounts, activeUin: rawActiveUin);
    } catch (_) {
      return AccountStoreSnapshot(
        accounts: const <AccountBinding>[],
        activeUin: "",
      );
    }
  }

  Future<void> save({
    required List<AccountBinding> accounts,
    required String activeUin,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = accounts.map((AccountBinding e) => e.toJson()).toList();
    await prefs.setString(_accountsKey, jsonEncode(payload));
    await prefs.setString(_activeUinKey, activeUin);
  }
}
