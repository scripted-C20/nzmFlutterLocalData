class OverviewStats {
  const OverviewStats({
    required this.totalGames,
    required this.winRate,
    required this.avgScore,
    required this.totalDamage,
    required this.totalWin,
    required this.totalLoss,
    this.recentGames,
    this.recentWinRate,
    this.recentAvgScore,
  });

  final int totalGames;
  final double winRate;
  final int avgScore;
  final int totalDamage;
  final int totalWin;
  final int totalLoss;
  final int? recentGames;
  final double? recentWinRate;
  final int? recentAvgScore;

  factory OverviewStats.empty() {
    return const OverviewStats(
      totalGames: 0,
      winRate: 0,
      avgScore: 0,
      totalDamage: 0,
      totalWin: 0,
      totalLoss: 0,
      recentGames: 0,
      recentWinRate: 0,
      recentAvgScore: 0,
    );
  }
}

class ModeStatsEntry {
  const ModeStatsEntry({
    required this.modeName,
    required this.games,
    required this.wins,
    required this.losses,
  });

  final String modeName;
  final int games;
  final int wins;
  final int losses;
}

class MapStatsEntry {
  const MapStatsEntry({
    required this.mapName,
    required this.games,
    required this.winCount,
    required this.winRate,
    this.iconUrl = "",
    this.difficulties = const <MapDifficultyEntry>[],
  });

  final String mapName;
  final int games;
  final int winCount;
  final double winRate;
  final String iconUrl;
  final List<MapDifficultyEntry> difficulties;
}

class MapDifficultyEntry {
  const MapDifficultyEntry({
    required this.diffName,
    required this.games,
    required this.winCount,
    required this.winRate,
  });

  final String diffName;
  final int games;
  final int winCount;
  final double winRate;
}

class FragmentProgress {
  const FragmentProgress({
    required this.name,
    required this.current,
    required this.target,
    this.iconUrl = "",
  });

  final String name;
  final int current;
  final int target;
  final String iconUrl;

  double get progress {
    if (target <= 0) {
      return 0;
    }
    return (current / target).clamp(0, 1);
  }
}

class StatsData {
  const StatsData({
    required this.overview,
    required this.modeStats,
    required this.mapStats,
    required this.fragments,
  });

  final OverviewStats overview;
  final List<ModeStatsEntry> modeStats;
  final List<MapStatsEntry> mapStats;
  final List<FragmentProgress> fragments;

  factory StatsData.empty() {
    return StatsData(
      overview: OverviewStats.empty(),
      modeStats: const <ModeStatsEntry>[],
      mapStats: const <MapStatsEntry>[],
      fragments: const <FragmentProgress>[],
    );
  }
}

class HistoryPageData {
  const HistoryPageData({
    required this.records,
    required this.page,
    required this.limit,
    required this.totalPages,
    required this.totalCount,
    this.modeOptions = const <String, String>{},
    this.difficultyOptions = const <String, String>{},
    this.mapOptions = const <String, String>{},
  });

  final List<BattleRecord> records;
  final int page;
  final int limit;
  final int totalPages;
  final int totalCount;
  final Map<String, String> modeOptions;
  final Map<String, String> difficultyOptions;
  final Map<String, String> mapOptions;
}

class BattleRecord {
  const BattleRecord({
    required this.roomId,
    required this.mapName,
    required this.modeName,
    required this.difficultyName,
    required this.score,
    required this.isWin,
    required this.timeText,
    required this.source,
    this.sourceType = "official-sync",
    this.mapId = 0,
    this.durationSeconds = 0,
    this.startTimeText = "",
    this.eventTimeRaw = "",
    this.bossDamage = 0,
    this.modeType = 0,
    this.remarkText = "",
    this.remarkModeNth = 0,
    this.remarkUpdatedAt = 0,
  });

  final String roomId;
  final String mapName;
  final String modeName;
  final String difficultyName;
  final int score;
  final bool isWin;
  final String timeText;
  final String source;
  final String sourceType;
  final int mapId;
  final int durationSeconds;
  final String startTimeText;
  final String eventTimeRaw;
  final int bossDamage;
  final int modeType;
  final String remarkText;
  final int remarkModeNth;
  final int remarkUpdatedAt;

  BattleRecord copyWith({
    String? roomId,
    String? mapName,
    String? modeName,
    String? difficultyName,
    int? score,
    bool? isWin,
    String? timeText,
    String? source,
    String? sourceType,
    int? mapId,
    int? durationSeconds,
    String? startTimeText,
    String? eventTimeRaw,
    int? bossDamage,
    int? modeType,
    String? remarkText,
    int? remarkModeNth,
    int? remarkUpdatedAt,
  }) {
    return BattleRecord(
      roomId: roomId ?? this.roomId,
      mapName: mapName ?? this.mapName,
      modeName: modeName ?? this.modeName,
      difficultyName: difficultyName ?? this.difficultyName,
      score: score ?? this.score,
      isWin: isWin ?? this.isWin,
      timeText: timeText ?? this.timeText,
      source: source ?? this.source,
      sourceType: sourceType ?? this.sourceType,
      mapId: mapId ?? this.mapId,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      startTimeText: startTimeText ?? this.startTimeText,
      eventTimeRaw: eventTimeRaw ?? this.eventTimeRaw,
      bossDamage: bossDamage ?? this.bossDamage,
      modeType: modeType ?? this.modeType,
      remarkText: remarkText ?? this.remarkText,
      remarkModeNth: remarkModeNth ?? this.remarkModeNth,
      remarkUpdatedAt: remarkUpdatedAt ?? this.remarkUpdatedAt,
    );
  }

  factory BattleRecord.fromJson(Map<String, dynamic> json) {
    String firstText(List<String> keys, {String fallback = ""}) {
      for (final String key in keys) {
        final String value = "${json[key] ?? ""}".trim();
        if (value.isNotEmpty) {
          return value;
        }
      }
      return fallback;
    }

    int toInt(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse("${value ?? ""}".trim()) ?? 0;
    }

    String parseRemarkText() {
      final dynamic rawRemark = json["remark"];
      if (rawRemark is String) {
        final String text = rawRemark.trim();
        if (text.isNotEmpty) return text;
      } else if (rawRemark is Map) {
        final String text = "${rawRemark["text"] ?? rawRemark["remarkText"] ?? rawRemark["note"] ?? ""}".trim();
        if (text.isNotEmpty) return text;
      }
      return firstText(const <String>["remarkText", "note"]);
    }

    int parseRemarkNth() {
      final dynamic rawRemark = json["remark"];
      if (rawRemark is Map) {
        final int nested = toInt(rawRemark["modeNth"] ?? rawRemark["modeIndex"] ?? rawRemark["nth"]);
        if (nested > 0) return nested;
      }
      return toInt(json["remarkModeNth"] ?? json["remarkNth"] ?? json["modeNth"] ?? json["nth"]);
    }

    int parseRemarkUpdatedAt() {
      final dynamic rawRemark = json["remark"];
      if (rawRemark is Map) {
        final int nested = toInt(rawRemark["updatedAt"]);
        if (nested > 0) return nested;
      }
      return toInt(json["remarkUpdatedAt"]);
    }

    final String sourceType = firstText(
      const <String>["sourceType", "recordSource", "dataSource", "source"],
      fallback: "official-sync",
    );
    return BattleRecord(
      roomId: firstText(const <String>[
        "roomId",
        "roomID",
        "dsRoomId",
        "DsRoomId",
        "sRoomID",
        "id",
      ]),
      mapName: firstText(const <String>["mapName", "sMapName", "map"]),
      modeName: firstText(const <String>["modeName", "sModeName", "mode"]),
      difficultyName: firstText(const <String>[
        "difficultyName",
        "diffName",
        "difficulty",
      ]),
      score: toInt(json["score"] ?? json["iScore"]),
      isWin: toInt(json["isWin"] ?? json["iIsWin"]) == 1 ||
          "${json["isWin"]}".toLowerCase() == "true",
      timeText:
          firstText(const <String>["timeText", "dtEventTime", "eventTime"]),
      source: sourceType == "json-transfer" ? "本地" : "官方",
      sourceType: sourceType,
      mapId: toInt(json["mapId"] ?? json["iMapId"]),
      durationSeconds: toInt(json["duration"] ?? json["iDuration"]),
      startTimeText: firstText(const <String>["startTime", "dtGameStartTime"]),
      eventTimeRaw: firstText(const <String>["eventTime", "dtEventTime"]),
      bossDamage: toInt(json["iBossDamage"] ?? json["bossDamage"] ?? json["iDamage"] ?? json["iTotalDamage"] ?? json["damage"] ?? json["totalDamage"]),
      modeType: toInt(json["iModeType"] ?? json["modeType"] ?? json["iGameMode"] ?? json["gameMode"] ?? json["iMode"]),
      remarkText: parseRemarkText(),
      remarkModeNth: parseRemarkNth(),
      remarkUpdatedAt: parseRemarkUpdatedAt(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      "dsRoomId": roomId,
      "roomId": roomId,
      "mapName": mapName,
      "mapId": mapId,
      "modeName": modeName,
      "diffName": difficultyName,
      "eventTime": eventTimeRaw.isNotEmpty ? eventTimeRaw : timeText,
      "startTime": startTimeText,
      "score": score,
      "duration": durationSeconds,
      "isWin": isWin ? 1 : 0,
      "sourceType": sourceType,
      "bossDamage": bossDamage,
      "modeType": modeType,
      "remarkText": remarkText,
      "remarkModeNth": remarkModeNth,
      "remarkUpdatedAt": remarkUpdatedAt,
    };
  }
}

class BattleRemark {
  const BattleRemark({
    required this.modeNth,
    required this.text,
    this.updatedAt = 0,
  });

  final int modeNth;
  final String text;
  final int updatedAt;

  BattleRemark copyWith({
    int? modeNth,
    String? text,
    int? updatedAt,
  }) {
    return BattleRemark(
      modeNth: modeNth ?? this.modeNth,
      text: text ?? this.text,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory BattleRemark.fromJson(Map<String, dynamic> json) {
    int toInt(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse("${value ?? ""}".trim()) ?? 0;
    }

    final String text = "${json["text"] ?? json["remarkText"] ?? ""}".trim();
    return BattleRemark(
      modeNth: toInt(json["modeNth"] ?? json["modeIndex"] ?? json["nth"]),
      text: text,
      updatedAt: toInt(json["updatedAt"]),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      "modeNth": modeNth,
      "text": text,
      "updatedAt": updatedAt,
    };
  }
}

class CollectionItem {
  const CollectionItem({
    required this.name,
    required this.type,
    required this.owned,
    required this.quality,
    required this.iconUrl,
  });

  final String name;
  final String type;
  final bool owned;
  final String quality;
  final String iconUrl;
}

class CollectionData {
  const CollectionData({
    required this.weapons,
    required this.traps,
    required this.plugins,
    required this.home,
  });

  final List<CollectionItem> weapons;
  final List<CollectionItem> traps;
  final List<CollectionItem> plugins;
  final List<CollectionItem> home;

  factory CollectionData.empty() {
    return const CollectionData(
      weapons: <CollectionItem>[],
      traps: <CollectionItem>[],
      plugins: <CollectionItem>[],
      home: <CollectionItem>[],
    );
  }
}

class LocalStatsData {
  const LocalStatsData({
    required this.totalRecords,
    required this.manualRows,
    required this.mapStats,
    required this.records,
  });

  final int totalRecords;
  final int manualRows;
  final List<MapStatsEntry> mapStats;
  final List<BattleRecord> records;

  factory LocalStatsData.empty() {
    return const LocalStatsData(
      totalRecords: 0,
      manualRows: 0,
      mapStats: <MapStatsEntry>[],
      records: <BattleRecord>[],
    );
  }
}

class RemoteUserInfo {
  const RemoteUserInfo({
    required this.uin,
    required this.nickname,
    required this.avatar,
  });

  final String uin;
  final String nickname;
  final String avatar;
}

class MatchPlayerDetail {
  const MatchPlayerDetail({
    required this.nickname,
    required this.avatarUrl,
    required this.isSelf,
    required this.totalCoin,
    required this.bossDamage,
    required this.mobsDamage,
    required this.score,
    required this.kills,
    required this.deaths,
    required this.partitionDetails,
    required this.equipments,
  });

  final String nickname;
  final String avatarUrl;
  final bool isSelf;
  final int totalCoin;
  final int bossDamage;
  final int mobsDamage;
  final int score;
  final int kills;
  final int deaths;
  final List<MatchPartitionDetail> partitionDetails;
  final List<MatchEquipment> equipments;
}

class MatchPartitionDetail {
  const MatchPartitionDetail({
    required this.areaId,
    required this.areaName,
    required this.usedTime,
  });

  final String areaId;
  final String areaName;
  final int usedTime;
}

class MatchEquipment {
  const MatchEquipment({
    required this.name,
    required this.iconUrl,
    required this.commonItems,
  });

  final String name;
  final String iconUrl;
  final List<MatchCommonItem> commonItems;
}

class MatchCommonItem {
  const MatchCommonItem({required this.name, required this.iconUrl});

  final String name;
  final String iconUrl;
}

class MatchDetailData {
  const MatchDetailData({
    required this.roomId,
    required this.players,
    required this.rawPayload,
  });

  final String roomId;
  final List<MatchPlayerDetail> players;
  final Map<String, dynamic> rawPayload;
}
