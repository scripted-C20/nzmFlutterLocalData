import "dart:convert";
import "dart:io";
import "dart:math";

import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";

import "../models/dashboard_models.dart";

class DashboardCacheSnapshot {
  const DashboardCacheSnapshot({
    required this.statsData,
    required this.collectionData,
    required this.historyPageData,
    required this.updatedAt,
  });

  final StatsData statsData;
  final CollectionData collectionData;
  final HistoryPageData historyPageData;
  final int updatedAt;

  bool get isEmpty {
    return statsData.modeStats.isEmpty &&
        statsData.mapStats.isEmpty &&
        statsData.fragments.isEmpty &&
        historyPageData.records.isEmpty &&
        collectionData.weapons.isEmpty &&
        collectionData.traps.isEmpty &&
        collectionData.plugins.isEmpty &&
        collectionData.home.isEmpty;
  }

  factory DashboardCacheSnapshot.empty() {
    return DashboardCacheSnapshot(
      statsData: StatsData.empty(),
      collectionData: CollectionData.empty(),
      historyPageData: const HistoryPageData(
        records: <BattleRecord>[],
        page: 1,
        limit: 10,
        totalPages: 1,
        totalCount: 0,
      ),
      updatedAt: 0,
    );
  }
}

class DashboardCacheStore {
  Future<DashboardCacheSnapshot> loadByUin(String uin) async {
    final String normalized = uin.trim();
    if (normalized.isEmpty) return DashboardCacheSnapshot.empty();
    final File file = await _resolveCacheFile(normalized);
    if (!await file.exists()) return DashboardCacheSnapshot.empty();
    try {
      final String text = await file.readAsString();
      final dynamic decoded = jsonDecode(text);
      if (decoded is! Map) return DashboardCacheSnapshot.empty();
      final Map<String, dynamic> payload = _asMap(decoded);
      return DashboardCacheSnapshot(
        statsData: _statsFromJson(_asMap(payload["stats"])),
        collectionData: _collectionFromJson(_asMap(payload["collection"])),
        historyPageData: _historyPageFromJson(_asMap(payload["history"])),
        updatedAt: _toInt(payload["updatedAt"]),
      );
    } catch (_) {
      return DashboardCacheSnapshot.empty();
    }
  }

  Future<void> saveByUin({
    required String uin,
    required StatsData statsData,
    required CollectionData collectionData,
    required HistoryPageData historyPageData,
  }) async {
    final String normalized = uin.trim();
    if (normalized.isEmpty) return;
    final File file = await _resolveCacheFile(normalized);
    final Map<String, dynamic> payload = <String, dynamic>{
      "uin": normalized,
      "updatedAt": DateTime.now().millisecondsSinceEpoch,
      "stats": _statsToJson(statsData),
      "collection": _collectionToJson(collectionData),
      "history": _historyPageToJson(historyPageData),
    };
    await file.create(recursive: true);
    await file.writeAsString(jsonEncode(payload));
  }

  Future<File> _resolveCacheFile(String uin) async {
    final Directory base = await getApplicationDocumentsDirectory();
    final Directory dir = Directory(p.join(base.path, "nzm"));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File(p.join(dir.path, "dashboard-cache-$uin.json"));
  }

  Map<String, dynamic> _statsToJson(StatsData data) {
    return <String, dynamic>{
      "overview": <String, dynamic>{
        "totalGames": data.overview.totalGames,
        "winRate": data.overview.winRate,
        "avgScore": data.overview.avgScore,
        "totalDamage": data.overview.totalDamage,
        "totalWin": data.overview.totalWin,
        "totalLoss": data.overview.totalLoss,
        "recentGames": data.overview.recentGames ?? 0,
        "recentWinRate": data.overview.recentWinRate ?? 0,
        "recentAvgScore": data.overview.recentAvgScore ?? 0,
      },
      "modeStats": data.modeStats
          .map((ModeStatsEntry e) => <String, dynamic>{
                "modeName": e.modeName,
                "games": e.games,
                "wins": e.wins,
                "losses": e.losses,
              })
          .toList(),
      "mapStats": data.mapStats
          .map((MapStatsEntry e) => <String, dynamic>{
                "mapName": e.mapName,
                "games": e.games,
                "winCount": e.winCount,
                "winRate": e.winRate,
                "iconUrl": e.iconUrl,
                "difficulties": e.difficulties
                    .map((MapDifficultyEntry d) => <String, dynamic>{
                          "diffName": d.diffName,
                          "games": d.games,
                          "winCount": d.winCount,
                          "winRate": d.winRate,
                        })
                    .toList(),
              })
          .toList(),
      "fragments": data.fragments
          .map((FragmentProgress e) => <String, dynamic>{
                "name": e.name,
                "current": e.current,
                "target": e.target,
                "iconUrl": e.iconUrl,
              })
          .toList(),
    };
  }

  StatsData _statsFromJson(Map<String, dynamic> raw) {
    if (raw.isEmpty) return StatsData.empty();
    final Map<String, dynamic> overview = _asMap(raw["overview"]);
    final List<ModeStatsEntry> modes = _asList(raw["modeStats"])
        .map(_asMap)
        .where((Map<String, dynamic> e) => e.isNotEmpty)
        .map((Map<String, dynamic> e) => ModeStatsEntry(
              modeName: _toText(e["modeName"]),
              games: _toInt(e["games"]),
              wins: _toInt(e["wins"]),
              losses: _toInt(e["losses"]),
            ))
        .toList();
    final List<MapStatsEntry> maps = _asList(raw["mapStats"])
        .map(_asMap)
        .where((Map<String, dynamic> e) => e.isNotEmpty)
        .map((Map<String, dynamic> e) {
      final List<MapDifficultyEntry> diffs = _asList(e["difficulties"])
          .map(_asMap)
          .where((Map<String, dynamic> d) => d.isNotEmpty)
          .map((Map<String, dynamic> d) => MapDifficultyEntry(
                diffName: _toText(d["diffName"]),
                games: _toInt(d["games"]),
                winCount: _toInt(d["winCount"]),
                winRate: _toDouble(d["winRate"]),
              ))
          .toList();
      return MapStatsEntry(
        mapName: _toText(e["mapName"]),
        games: _toInt(e["games"]),
        winCount: _toInt(e["winCount"]),
        winRate: _toDouble(e["winRate"]),
        iconUrl: _toText(e["iconUrl"]),
        difficulties: diffs,
      );
    }).toList();
    final List<FragmentProgress> fragments = _asList(raw["fragments"])
        .map(_asMap)
        .where((Map<String, dynamic> e) => e.isNotEmpty)
        .map((Map<String, dynamic> e) => FragmentProgress(
              name: _toText(e["name"]),
              current: _toInt(e["current"]),
              target: _toInt(e["target"]),
              iconUrl: _toText(e["iconUrl"]),
            ))
        .toList();
    return StatsData(
      overview: OverviewStats(
        totalGames: _toInt(overview["totalGames"]),
        winRate: _toDouble(overview["winRate"]),
        avgScore: _toInt(overview["avgScore"]),
        totalDamage: _toInt(overview["totalDamage"]),
        totalWin: _toInt(overview["totalWin"]),
        totalLoss: _toInt(overview["totalLoss"]),
        recentGames: _toInt(overview["recentGames"]),
        recentWinRate: _toDouble(overview["recentWinRate"]),
        recentAvgScore: _toInt(overview["recentAvgScore"]),
      ),
      modeStats: modes,
      mapStats: maps,
      fragments: fragments,
    );
  }

  Map<String, dynamic> _collectionToJson(CollectionData data) {
    List<Map<String, dynamic>> mapItems(List<CollectionItem> items) {
      return items
          .map((CollectionItem e) => <String, dynamic>{
                "name": e.name,
                "type": e.type,
                "owned": e.owned,
                "quality": e.quality,
                "iconUrl": e.iconUrl,
              })
          .toList();
    }

    return <String, dynamic>{
      "weapons": mapItems(data.weapons),
      "traps": mapItems(data.traps),
      "plugins": mapItems(data.plugins),
      "home": mapItems(data.home),
    };
  }

  CollectionData _collectionFromJson(Map<String, dynamic> raw) {
    List<CollectionItem> parseItems(dynamic value) {
      return _asList(value)
          .map(_asMap)
          .where((Map<String, dynamic> e) => e.isNotEmpty)
          .map((Map<String, dynamic> e) => CollectionItem(
                name: _toText(e["name"]),
                type: _toText(e["type"]),
                owned: _toBool(e["owned"]),
                quality: _toText(e["quality"]),
                iconUrl: _toText(e["iconUrl"]),
              ))
          .toList();
    }

    return CollectionData(
      weapons: parseItems(raw["weapons"]),
      traps: parseItems(raw["traps"]),
      plugins: parseItems(raw["plugins"]),
      home: parseItems(raw["home"]),
    );
  }

  Map<String, dynamic> _historyPageToJson(HistoryPageData data) {
    return <String, dynamic>{
      "page": data.page,
      "limit": data.limit,
      "totalPages": data.totalPages,
      "totalCount": data.totalCount,
      "modeOptions": data.modeOptions,
      "difficultyOptions": data.difficultyOptions,
      "mapOptions": data.mapOptions,
      "records": data.records.map((BattleRecord e) => e.toJson()).toList(),
    };
  }

  HistoryPageData _historyPageFromJson(Map<String, dynamic> raw) {
    final List<BattleRecord> records = _asList(raw["records"])
        .map(_asMap)
        .where((Map<String, dynamic> e) => e.isNotEmpty)
        .map((Map<String, dynamic> e) => BattleRecord.fromJson(e))
        .toList();
    final Map<String, String> modeOptions = <String, String>{};
    _asMap(raw["modeOptions"]).forEach((String key, dynamic value) {
      final String k = key.trim();
      final String v = _toText(value);
      if (k.isNotEmpty && v.isNotEmpty) {
        modeOptions[k] = v;
      }
    });
    final Map<String, String> difficultyOptions = <String, String>{};
    _asMap(raw["difficultyOptions"]).forEach((String key, dynamic value) {
      final String k = key.trim();
      final String v = _toText(value);
      if (k.isNotEmpty && v.isNotEmpty) {
        difficultyOptions[k] = v;
      }
    });
    final Map<String, String> mapOptions = <String, String>{};
    _asMap(raw["mapOptions"]).forEach((String key, dynamic value) {
      final String k = key.trim();
      final String v = _toText(value);
      if (k.isNotEmpty && v.isNotEmpty) {
        mapOptions[k] = v;
      }
    });
    return HistoryPageData(
      records: records,
      page: max(1, _toInt(raw["page"])),
      limit: max(1, _toInt(raw["limit"])),
      totalPages: max(1, _toInt(raw["totalPages"])),
      totalCount: _toInt(raw["totalCount"]),
      modeOptions: modeOptions,
      difficultyOptions: difficultyOptions,
      mapOptions: mapOptions,
    );
  }

  List<dynamic> _asList(dynamic value) {
    return value is List ? value : const <dynamic>[];
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map) {
      final Map<String, dynamic> out = <String, dynamic>{};
      value.forEach((dynamic key, dynamic item) {
        out["${key ?? ""}"] = item;
      });
      return out;
    }
    return <String, dynamic>{};
  }

  String _toText(dynamic value) {
    return "${value ?? ""}".trim();
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse("${value ?? ""}".replaceAll(",", "").trim()) ?? 0;
  }

  double _toDouble(dynamic value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse("${value ?? ""}".replaceAll(",", "").trim()) ?? 0;
  }

  bool _toBool(dynamic value) {
    if (value is bool) return value;
    final String raw = "${value ?? ""}".trim().toLowerCase();
    return raw == "1" || raw == "true" || raw == "yes";
  }
}
