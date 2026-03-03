import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:file_picker/file_picker.dart";
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";

import "../models/dashboard_models.dart";

const String localJsonTransferMark = "local-records-transfer";

class LocalJsonFormatException implements Exception {
  const LocalJsonFormatException([this.message = "JSON格式错误"]);

  final String message;

  @override
  String toString() => message;
}

class LocalJsonUinMismatchException implements Exception {
  const LocalJsonUinMismatchException({
    required this.payloadUin,
    required this.targetUin,
  });

  final String payloadUin;
  final String targetUin;

  @override
  String toString() {
    final String left = payloadUin.isEmpty ? "缺失" : payloadUin;
    return "uin不一致（JSON: $left / 当前: $targetUin）";
  }
}

class LocalJsonEmptyRecordsException implements Exception {
  const LocalJsonEmptyRecordsException([this.message = "records为空"]);

  final String message;

  @override
  String toString() => message;
}

class LocalJsonImportResult {
  const LocalJsonImportResult({
    required this.records,
    required this.localStatsData,
    required this.inserted,
    required this.updated,
    required this.totalRecords,
    required this.filePath,
  });

  final List<BattleRecord> records;
  final LocalStatsData localStatsData;
  final int inserted;
  final int updated;
  final int totalRecords;
  final String filePath;
}

class LocalJsonExportResult {
  const LocalJsonExportResult({
    required this.filePath,
    required this.count,
    required this.uin,
  });

  final String filePath;
  final int count;
  final String uin;
}

class LocalRecordsStore {
  Future<LocalStatsData> loadStatsByUin(String uin) async {
    final List<BattleRecord> records = await loadRecordsByUin(uin);
    return buildLocalStatsFromRecords(records);
  }

  Future<List<BattleRecord>> loadRecordsByUin(String uin) async {
    final String normalizedUin = _normalizeUin(uin);
    if (normalizedUin.isEmpty) return const <BattleRecord>[];

    final File file = await _resolveStoreFile(normalizedUin);
    if (!await file.exists()) return const <BattleRecord>[];

    try {
      final String text = await file.readAsString();
      final dynamic decoded = jsonDecode(text);
      final Map<String, dynamic> payload =
          decoded is Map ? _toStringKeyedMap(decoded) : <String, dynamic>{};
      final dynamic rawRecords = payload["records"];
      if (rawRecords is! List) return const <BattleRecord>[];
      final List<BattleRecord> parsed = rawRecords
          .map(_battleRecordFromDynamic)
          .whereType<BattleRecord>()
          .toList();
      final bool hasLegacyRemarks = payload["remarks"] is Map &&
          (payload["remarks"] as Map).isNotEmpty;
      List<BattleRecord> deduped = _dedupeRecords(parsed);
      if (hasLegacyRemarks) {
        deduped = _applyRemarksToRecords(deduped, _parseRemarks(payload["remarks"]));
      }
      if (deduped.length != parsed.length || hasLegacyRemarks) {
        await _persistAll(file: file, uin: normalizedUin, records: deduped);
      }
      return deduped;
    } catch (_) {
      return const <BattleRecord>[];
    }
  }

  Future<Map<String, BattleRemark>> loadRemarksByUin(String uin) async {
    final String normalizedUin = _normalizeUin(uin);
    if (normalizedUin.isEmpty) return <String, BattleRemark>{};

    final File file = await _resolveStoreFile(normalizedUin);
    if (!await file.exists()) return <String, BattleRemark>{};
    final List<BattleRecord> records = await loadRecordsByUin(normalizedUin);
    final Map<String, BattleRemark> fromRecords = _collectRemarksFromRecords(records);
    final Map<String, dynamic> payload = await _readStorePayload(file);
    final Map<String, BattleRemark> fromLegacy = _parseRemarks(payload["remarks"]);
    if (fromLegacy.isEmpty) {
      return fromRecords;
    }
    final Map<String, BattleRemark> merged =
        _mergeRemarkMaps(fromRecords, fromLegacy);
    final List<BattleRecord> migrated = _applyRemarksToRecords(records, merged);
    await _persistAll(file: file, uin: normalizedUin, records: migrated);
    return merged;
  }

  Future<void> persistRecords({
    required String uin,
    required List<BattleRecord> records,
  }) async {
    final String normalizedUin = _normalizeUin(uin);
    if (normalizedUin.isEmpty) return;

    final List<BattleRecord> cleaned = _dedupeRecords(records);
    final File file = await _resolveStoreFile(normalizedUin);
    await _persistAll(file: file, uin: normalizedUin, records: cleaned);
  }

  Future<void> persistRemarksByUin({
    required String uin,
    required Map<String, BattleRemark> remarks,
  }) async {
    final String normalizedUin = _normalizeUin(uin);
    if (normalizedUin.isEmpty) return;
    final File file = await _resolveStoreFile(normalizedUin);
    final List<BattleRecord> records = await loadRecordsByUin(normalizedUin);
    final List<BattleRecord> merged = _applyRemarksToRecords(records, remarks);
    await _persistAll(file: file, uin: normalizedUin, records: merged);
  }

  Future<LocalJsonImportResult?> importByFilePicker({
    required String uin,
    required List<BattleRecord> currentRecords,
  }) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      dialogTitle: "导入本地记录（json）",
      type: FileType.custom,
      allowedExtensions: const <String>["json"],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;

    final PlatformFile picked = result.files.single;
    final String filePath = (picked.path ?? picked.name).trim();

    String text = "";
    final Uint8List? bytes = picked.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      text = utf8.decode(bytes);
    } else if ((picked.path ?? "").trim().isNotEmpty) {
      text = await File(picked.path!.trim()).readAsString();
    } else {
      throw Exception("未读取到导入文件内容");
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const LocalJsonFormatException();
    }
    final Map<String, dynamic> payload = decoded is Map
        ? _toStringKeyedMap(decoded)
        : throw const LocalJsonFormatException();
    return importFromPayload(
      uin: uin,
      currentRecords: currentRecords,
      payload: payload,
      filePath: filePath,
    );
  }

  Future<LocalJsonImportResult> importFromPayload({
    required String uin,
    required List<BattleRecord> currentRecords,
    required Map<String, dynamic> payload,
    String filePath = "",
  }) async {
    final String payloadUin = _normalizeUin("${payload["uin"] ?? ""}");
    final String targetUin = _normalizeUin(uin);
    if (targetUin.isEmpty) {
      throw Exception("当前账号缺少 uin，无法导入 JSON");
    }
    if (payloadUin.isEmpty || payloadUin != targetUin) {
      throw LocalJsonUinMismatchException(
        payloadUin: payloadUin,
        targetUin: targetUin,
      );
    }

    final List<dynamic> list = payload["records"] is List
        ? payload["records"] as List<dynamic>
        : payload["list"] is List
            ? payload["list"] as List<dynamic>
            : <dynamic>[];
    if (list.isEmpty) {
      throw const LocalJsonEmptyRecordsException();
    }
    final bool forceJsonTransfer =
        "${payload["transferMarker"] ?? ""}" == localJsonTransferMark ||
            "${payload["transferType"] ?? ""}".trim().toLowerCase() ==
                "local-export-import" ||
            "${payload["transferType"] ?? ""}".trim().toLowerCase() == "cloud";

    List<BattleRecord> incoming = list
        .map(_battleRecordFromDynamic)
        .whereType<BattleRecord>()
        .map((BattleRecord e) {
          if (!forceJsonTransfer) return e;
          return e.copyWith(sourceType: "json-transfer", source: "本地");
        })
        .where(_hasMinimalRecordData)
        .toList();
    if (incoming.isEmpty) {
      throw const LocalJsonEmptyRecordsException();
    }
    final Map<String, BattleRemark> incomingRemarks =
        _parseRemarks(payload["remarks"]);
    if (incomingRemarks.isNotEmpty) {
      incoming = _applyRemarksToRecords(incoming, incomingRemarks);
    }

    final _MergeResult merged = _mergeRecords(currentRecords, incoming);
    List<BattleRecord> mergedRecords = merged.records;
    if (incomingRemarks.isNotEmpty) {
      final Map<String, BattleRemark> mergedRemarkMap = _mergeRemarkMaps(
        _collectRemarksFromRecords(mergedRecords),
        incomingRemarks,
      );
      mergedRecords = _applyRemarksToRecords(mergedRecords, mergedRemarkMap);
    }
    final File file = await _resolveStoreFile(targetUin);
    await _persistAll(file: file, uin: targetUin, records: mergedRecords);
    final LocalStatsData stats = buildLocalStatsFromRecords(mergedRecords);
    return LocalJsonImportResult(
      records: mergedRecords,
      localStatsData: stats,
      inserted: merged.inserted,
      updated: merged.updated,
      totalRecords: mergedRecords.length,
      filePath: filePath,
    );
  }

  Future<LocalStatsData> upsertRecordsByUin({
    required String uin,
    required List<BattleRecord> incomingRecords,
  }) async {
    final String targetUin = _normalizeUin(uin);
    if (targetUin.isEmpty) return LocalStatsData.empty();
    if (incomingRecords.isEmpty) return loadStatsByUin(targetUin);

    final List<BattleRecord> current = await loadRecordsByUin(targetUin);
    final List<BattleRecord> filteredIncoming = incomingRecords
        .where(_hasMinimalRecordData)
        .toList();
    if (filteredIncoming.isEmpty) return buildLocalStatsFromRecords(current);

    final _MergeResult merged = _mergeRecords(current, filteredIncoming);
    await persistRecords(uin: targetUin, records: merged.records);
    return buildLocalStatsFromRecords(merged.records);
  }

  Future<LocalStatsData> clearImportedRecordsByUin({
    required String uin,
  }) async {
    final String targetUin = _normalizeUin(uin);
    if (targetUin.isEmpty) return LocalStatsData.empty();
    final List<BattleRecord> current = await loadRecordsByUin(targetUin);
    if (current.isEmpty) {
      return LocalStatsData.empty();
    }
    final List<BattleRecord> kept = current.where((BattleRecord record) {
      return _normalizeSourceType(record.sourceType) != "json-transfer";
    }).toList();
    final File file = await _resolveStoreFile(targetUin);
    await _persistAll(file: file, uin: targetUin, records: kept);
    return buildLocalStatsFromRecords(kept);
  }

  Future<LocalStatsData> clearAllRecordsByUin({
    required String uin,
  }) async {
    final String targetUin = _normalizeUin(uin);
    if (targetUin.isEmpty) return LocalStatsData.empty();
    final File file = await _resolveStoreFile(targetUin);
    if (await file.exists()) {
      await file.delete();
    }
    return LocalStatsData.empty();
  }

  Future<LocalJsonExportResult?> exportByFilePicker({
    required String uin,
    required List<BattleRecord> records,
  }) async {
    final String normalizedUin = _normalizeUin(uin);
    if (normalizedUin.isEmpty) {
      throw Exception("当前账号缺少 uin，无法导出 JSON");
    }
    final Map<String, dynamic> payload = buildTransferPayload(
      uin: normalizedUin,
      records: records,
      transferType: "local-export-import",
    );
    final String content = const JsonEncoder.withIndent("  ").convert(payload);
    final Uint8List bytes = Uint8List.fromList(utf8.encode(content));
    final String? savePath = await FilePicker.platform.saveFile(
      dialogTitle: "导出本地记录（json）",
      fileName: "local-records-$normalizedUin.json",
      type: FileType.custom,
      allowedExtensions: const <String>["json"],
      bytes: bytes,
    );
    if (savePath == null || savePath.trim().isEmpty) {
      return null;
    }
    return LocalJsonExportResult(
      filePath: savePath,
      count: records.length,
      uin: normalizedUin,
    );
  }

  Map<String, dynamic> buildTransferPayload({
    required String uin,
    required List<BattleRecord> records,
    required String transferType,
  }) {
    final String normalizedUin = _normalizeUin(uin);
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<Map<String, dynamic>> normalizedRecords = records
        .map((BattleRecord e) {
          final String normalizedSource = _normalizeSourceType(e.sourceType);
          final Map<String, dynamic> json = e
              .copyWith(
                sourceType: normalizedSource,
                source: normalizedSource == "json-transfer" ? "本地" : "官方",
              )
              .toJson();
          json["remarkText"] = "${json["remarkText"] ?? ""}".trim();
          json["remarkModeNth"] = _toInt(json["remarkModeNth"]);
          json["remarkUpdatedAt"] = _toInt(json["remarkUpdatedAt"]);
          return json;
        })
        .toList();

    return <String, dynamic>{
      "transferMarker": localJsonTransferMark,
      "transferType": transferType,
      "sourceType": "json-transfer",
      "uin": normalizedUin,
      "exportedAt": now,
      "count": normalizedRecords.length,
      "records": normalizedRecords,
    };
  }

  LocalStatsData buildLocalStatsFromRecords(List<BattleRecord> records) {
    final Map<String, _MapAgg> aggByMap = <String, _MapAgg>{};
    int manualRows = 0;
    for (final BattleRecord record in records) {
      final String key =
          record.mapName.trim().isEmpty ? "未知地图" : record.mapName.trim();
      final _MapAgg agg =
          aggByMap.putIfAbsent(key, () => _MapAgg(mapName: key));
      agg.games += 1;
      if (record.isWin) {
        agg.winCount += 1;
      }
      final String diffName = record.difficultyName.trim().isEmpty
          ? "未知难度"
          : record.difficultyName.trim();
      final _DiffAgg diff =
          agg.difficulty.putIfAbsent(diffName, () => _DiffAgg(diffName: diffName));
      diff.games += 1;
      if (record.isWin) {
        diff.winCount += 1;
      }
      if (_normalizeSourceType(record.sourceType) == "json-transfer") {
        manualRows += 1;
      }
    }

    final List<MapStatsEntry> mapStats = aggByMap.values.map((_MapAgg e) {
      final double rate = e.games > 0 ? e.winCount * 100 / e.games : 0;
      final List<MapDifficultyEntry> diffs =
          e.difficulty.values.map((_DiffAgg d) {
        final double diffRate = d.games > 0 ? d.winCount * 100 / d.games : 0;
        return MapDifficultyEntry(
          diffName: d.diffName,
          games: d.games,
          winCount: d.winCount,
          winRate: double.parse(diffRate.toStringAsFixed(1)),
        );
      }).toList()
            ..sort((MapDifficultyEntry a, MapDifficultyEntry b) =>
                b.games.compareTo(a.games));
      return MapStatsEntry(
        mapName: e.mapName,
        games: e.games,
        winCount: e.winCount,
        winRate: double.parse(rate.toStringAsFixed(1)),
        difficulties: diffs,
      );
    }).toList()
      ..sort((MapStatsEntry a, MapStatsEntry b) => b.games.compareTo(a.games));

    return LocalStatsData(
      totalRecords: records.length,
      manualRows: manualRows,
      mapStats: mapStats,
      records: records,
    );
  }

  Future<Map<String, dynamic>> buildCloudPayload({
    required String uin,
    required List<BattleRecord> records,
  }) async {
    final Map<String, dynamic> payload = buildTransferPayload(
      uin: uin,
      records: records,
      transferType: "cloud",
    );
    payload["cloudSyncedAt"] = DateTime.now().millisecondsSinceEpoch;
    return payload;
  }

  Future<String> getStorePathByUin(String uin) async {
    final File file = await _resolveStoreFile(_normalizeUin(uin));
    return file.path;
  }

  Future<File> _resolveStoreFile(String uin) async {
    final Directory base = await getApplicationDocumentsDirectory();
    final Directory dir = Directory(p.join(base.path, "nzm"));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final String fileName = "local-stats$uin.json";
    return File(p.join(dir.path, fileName));
  }

  _MergeResult _mergeRecords(
    List<BattleRecord> current,
    List<BattleRecord> incoming,
  ) {
    final Map<String, BattleRecord> byIdentity = <String, BattleRecord>{};
    for (final BattleRecord item in current) {
      final String key = _recordIdentityKey(item);
      if (key.isEmpty) continue;
      byIdentity[key] = _pickBetterRecord(byIdentity[key], item);
    }
    int inserted = 0;
    int updated = 0;
    for (final BattleRecord item in incoming) {
      final String key = _recordIdentityKey(item);
      if (key.isEmpty) continue;
      if (byIdentity.containsKey(key)) {
        byIdentity[key] = _pickBetterRecord(byIdentity[key], item);
        updated += 1;
      } else {
        byIdentity[key] = item;
        inserted += 1;
      }
    }
    final List<BattleRecord> records = byIdentity.values.toList()
      ..sort((BattleRecord a, BattleRecord b) =>
          _recordTimeMs(b).compareTo(_recordTimeMs(a)));
    return _MergeResult(records: records, inserted: inserted, updated: updated);
  }

  List<BattleRecord> _dedupeRecords(List<BattleRecord> source) {
    final Map<String, BattleRecord> byIdentity = <String, BattleRecord>{};
    for (final BattleRecord item in source) {
      if (!_hasMinimalRecordData(item)) continue;
      final String key = _recordIdentityKey(item);
      if (key.isEmpty) continue;
      byIdentity[key] = _pickBetterRecord(byIdentity[key], item);
    }
    final List<BattleRecord> out = byIdentity.values.toList()
      ..sort((BattleRecord a, BattleRecord b) =>
          _recordTimeMs(b).compareTo(_recordTimeMs(a)));
    return out;
  }

  bool _hasMinimalRecordData(BattleRecord record) {
    if (record.roomId.trim().isNotEmpty) return true;
    if (record.eventTimeRaw.trim().isNotEmpty) return true;
    if (record.timeText.trim().isNotEmpty) return true;
    if (record.startTimeText.trim().isNotEmpty) return true;
    if (record.mapName.trim().isNotEmpty) return true;
    if (record.modeName.trim().isNotEmpty) return true;
    return false;
  }

  String _recordIdentityKey(BattleRecord record) {
    final String roomId = _normalizeRoomId(record.roomId);
    if (roomId.isNotEmpty) {
      return "room:$roomId";
    }
    final String mapKey = record.mapId > 0
        ? "id:${record.mapId}"
        : record.mapName.trim().toLowerCase();
    final String modeKey = record.modeType > 0
        ? "mode:${record.modeType}"
        : record.modeName.trim().toLowerCase();
    final String diffKey = record.difficultyName.trim().toLowerCase();
    final int ts = _recordTimeMs(record);
    final int duration = record.durationSeconds > 0 ? record.durationSeconds : 0;
    final int score = record.score > 0 ? record.score : 0;
    return "fallback:$ts|$duration|$score|$mapKey|$modeKey|$diffKey";
  }

  String _normalizeRoomId(String value) {
    final String raw = value.trim();
    if (raw.isEmpty) return "";
    return raw.replaceAll(RegExp(r"[^0-9A-Za-z_-]"), "").toLowerCase();
  }

  BattleRecord _pickBetterRecord(BattleRecord? a, BattleRecord b) {
    if (a == null) return b;
    final int scoreA = _recordCompletenessScore(a);
    final int scoreB = _recordCompletenessScore(b);
    if (scoreB > scoreA) return _mergeRecordRemark(primary: b, secondary: a);
    if (scoreA > scoreB) return _mergeRecordRemark(primary: a, secondary: b);
    if (_recordTimeMs(b) >= _recordTimeMs(a)) {
      return _mergeRecordRemark(primary: b, secondary: a);
    }
    return _mergeRecordRemark(primary: a, secondary: b);
  }

  BattleRecord _mergeRecordRemark({
    required BattleRecord primary,
    required BattleRecord secondary,
  }) {
    final BattleRemark? primaryRemark = _remarkFromRecord(primary);
    final BattleRemark? secondaryRemark = _remarkFromRecord(secondary);
    BattleRemark? preferred = primaryRemark;
    if (secondaryRemark != null) {
      preferred = _pickPreferredRemark(preferred, secondaryRemark);
    }
    if (preferred == null || preferred.text.trim().isEmpty) {
      return primary.copyWith(
        remarkText: "",
        remarkModeNth: 0,
        remarkUpdatedAt: 0,
      );
    }
    return primary.copyWith(
      remarkText: _sanitizeRemarkText(preferred.text),
      remarkModeNth: preferred.modeNth < 0 ? 0 : preferred.modeNth,
      remarkUpdatedAt: preferred.updatedAt < 0 ? 0 : preferred.updatedAt,
    );
  }

  int _recordCompletenessScore(BattleRecord record) {
    int score = 0;
    if (record.roomId.trim().isNotEmpty) score += 5;
    if (record.eventTimeRaw.trim().isNotEmpty || record.timeText.trim().isNotEmpty) {
      score += 2;
    }
    if (record.mapName.trim().isNotEmpty || record.mapId > 0) score += 2;
    if (record.modeName.trim().isNotEmpty || record.modeType > 0) score += 2;
    if (record.difficultyName.trim().isNotEmpty) score += 1;
    if (record.durationSeconds > 0) score += 1;
    if (record.score > 0) score += 1;
    if (record.bossDamage > 0) score += 1;
    if (record.remarkText.trim().isNotEmpty) score += 1;
    return score;
  }

  int _recordTimeMs(BattleRecord record) {
    DateTime? parse(String text) {
      final String raw = text.trim();
      if (raw.isEmpty) return null;
      return DateTime.tryParse(raw.replaceAll("/", "-"));
    }

    final DateTime? event = parse(record.eventTimeRaw);
    if (event != null) return event.millisecondsSinceEpoch;
    final DateTime? shown = parse(record.timeText);
    if (shown != null) return shown.millisecondsSinceEpoch;
    final DateTime? start = parse(record.startTimeText);
    if (start != null) return start.millisecondsSinceEpoch;
    return 0;
  }

  String _normalizeUin(String value) {
    return value.trim();
  }

  String _normalizeSourceType(String sourceType) {
    final String raw = sourceType.trim().toLowerCase();
    if (raw == "json-transfer" ||
        raw == "json-import" ||
        raw == "json_import" ||
        raw == "local-export-import" ||
        raw == "local-json" ||
        raw == "cloud") {
      return "json-transfer";
    }
    return "official-sync";
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse("${value ?? ""}".trim()) ?? 0;
  }

  Future<Map<String, dynamic>> _readStorePayload(File file) async {
    try {
      final String text = await file.readAsString();
      final dynamic decoded = jsonDecode(text);
      if (decoded is Map) {
        return _toStringKeyedMap(decoded);
      }
    } catch (_) {
      // ignored
    }
    return <String, dynamic>{};
  }

  Future<void> _persistAll({
    required File file,
    required String uin,
    required List<BattleRecord> records,
  }) async {
    final Map<String, dynamic> payload = <String, dynamic>{
      "uin": uin,
      "updatedAt": DateTime.now().millisecondsSinceEpoch,
      "count": records.length,
      "records": records.map((BattleRecord e) => e.toJson()).toList(),
    };
    await file.create(recursive: true);
    await file.writeAsString(jsonEncode(payload));
  }

  Map<String, BattleRemark> _parseRemarks(dynamic raw) {
    if (raw is! Map) return <String, BattleRemark>{};
    final Map<String, BattleRemark> out = <String, BattleRemark>{};
    final Map<dynamic, dynamic> source = Map<dynamic, dynamic>.from(raw);
    source.forEach((dynamic key, dynamic value) {
      final String recordKey = "${key ?? ""}".trim();
      if (recordKey.isEmpty) return;
      if (value is Map) {
        final BattleRemark remark =
            BattleRemark.fromJson(_toStringKeyedMap(value));
        if (remark.text.trim().isEmpty) return;
        out[recordKey] = remark;
        return;
      }
      final String text = "${value ?? ""}".trim();
      if (text.isEmpty) return;
      out[recordKey] = BattleRemark(modeNth: 0, text: text);
    });
    return out;
  }

  Map<String, dynamic> _toStringKeyedMap(Map source) {
    final Map<String, dynamic> out = <String, dynamic>{};
    source.forEach((dynamic key, dynamic value) {
      out["${key ?? ""}"] = value;
    });
    return out;
  }

  BattleRecord? _battleRecordFromDynamic(dynamic value) {
    if (value is! Map) return null;
    try {
      return BattleRecord.fromJson(_toStringKeyedMap(value));
    } catch (_) {
      return null;
    }
  }

  String _sanitizeRemarkText(String value) {
    return value
        .replaceAll(RegExp(r"[\r\n\t]+"), " ")
        .replaceAll(RegExp(r"[<>]"), "")
        .replaceAll(RegExp(r"\s+"), " ")
        .trim();
  }

  BattleRemark? _remarkFromRecord(BattleRecord record) {
    final String text = _sanitizeRemarkText(record.remarkText);
    if (text.isEmpty) return null;
    return BattleRemark(
      modeNth: record.remarkModeNth < 0 ? 0 : record.remarkModeNth,
      text: text,
      updatedAt: record.remarkUpdatedAt < 0 ? 0 : record.remarkUpdatedAt,
    );
  }

  BattleRecord _applyRemarkToRecord(BattleRecord record, BattleRemark? remark) {
    if (remark == null || remark.text.trim().isEmpty) {
      return record.copyWith(
        remarkText: "",
        remarkModeNth: 0,
        remarkUpdatedAt: 0,
      );
    }
    return record.copyWith(
      remarkText: _sanitizeRemarkText(remark.text),
      remarkModeNth: remark.modeNth < 0 ? 0 : remark.modeNth,
      remarkUpdatedAt: remark.updatedAt < 0 ? 0 : remark.updatedAt,
    );
  }

  Map<String, BattleRemark> _collectRemarksFromRecords(List<BattleRecord> records) {
    final Map<String, BattleRemark> out = <String, BattleRemark>{};
    for (final BattleRecord record in records) {
      final String key = _recordIdentityKey(record);
      if (key.isEmpty) continue;
      final BattleRemark? remark = _remarkFromRecord(record);
      if (remark == null) continue;
      final BattleRemark? old = out[key];
      out[key] = _pickPreferredRemark(old, remark);
    }
    return out;
  }

  BattleRemark _pickPreferredRemark(BattleRemark? current, BattleRemark candidate) {
    if (current == null) return candidate;
    final int currentTs = current.updatedAt;
    final int candidateTs = candidate.updatedAt;
    if (candidateTs > currentTs) return candidate;
    if (candidateTs < currentTs) return current;
    if (candidate.text.length > current.text.length) return candidate;
    if (candidate.text.length < current.text.length) return current;
    if (candidate.modeNth > current.modeNth) return candidate;
    return current;
  }

  Map<String, BattleRemark> _mergeRemarkMaps(
    Map<String, BattleRemark> base,
    Map<String, BattleRemark> incoming,
  ) {
    final Map<String, BattleRemark> out = Map<String, BattleRemark>.from(base);
    incoming.forEach((String key, BattleRemark value) {
      final String recordKey = key.trim();
      if (recordKey.isEmpty) return;
      if (value.text.trim().isEmpty) {
        out.remove(recordKey);
        return;
      }
      out[recordKey] = _pickPreferredRemark(out[recordKey], value);
    });
    return out;
  }

  List<BattleRecord> _applyRemarksToRecords(
    List<BattleRecord> records,
    Map<String, BattleRemark> remarks,
  ) {
    return records.map((BattleRecord record) {
      final String key = _recordIdentityKey(record);
      if (key.isEmpty) return _applyRemarkToRecord(record, null);
      return _applyRemarkToRecord(record, remarks[key]);
    }).toList();
  }
}

class _MapAgg {
  _MapAgg({required this.mapName});

  final String mapName;
  int games = 0;
  int winCount = 0;
  final Map<String, _DiffAgg> difficulty = <String, _DiffAgg>{};
}

class _DiffAgg {
  _DiffAgg({required this.diffName});

  final String diffName;
  int games = 0;
  int winCount = 0;
}

class _MergeResult {
  const _MergeResult({
    required this.records,
    required this.inserted,
    required this.updated,
  });

  final List<BattleRecord> records;
  final int inserted;
  final int updated;
}

