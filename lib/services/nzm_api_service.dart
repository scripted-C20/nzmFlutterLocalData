import "dart:convert";
import "dart:math";

import "package:http/http.dart" as http;

import "../models/dashboard_models.dart";
import "api_log_service.dart";

class ApiUnauthorizedException implements Exception {
  ApiUnauthorizedException(this.message);

  final String message;

  @override
  String toString() => message;
}

class NzmApiService {
  NzmApiService({http.Client? client, ApiLogService? apiLogService})
      : _client = client ?? http.Client(),
        _apiLogService = apiLogService ?? ApiLogService.instance;

  final http.Client _client;
  final ApiLogService _apiLogService;

  static const String _officialDataApi = "https://comm.ams.game.qq.com/ide/";
  static const String _officialImageHost = "https://nzm.playerhub.qq.com/";

  static const String _recordPageReferer =
      "http://wechatmini.qq.com/-/-/pages/record/record/";
  static const String _recordInfoPageReferer =
      "http://wechatmini.qq.com/-/-/pages/recordinfo/recordinfo/";
  static const String _handbookPageReferer =
      "http://wechatmini.qq.com/-/-/pages/handbook/handbook/";

  static const String _defaultAppId = "1112451898";
  static const String _miniProgramUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36 "
      "MicroMessenger/7.0.20.1781(0x6700143B) NetType/WIFI "
      "MiniProgramEnv/Windows WindowsWechat/WMPF WindowsWechat(0x63090a13) "
      "UnifiedPCWindowsWechat(0xf254171e) XWEB/18787";

  String buildCookie({
    required String openid,
    required String accessToken,
    String appid = _defaultAppId,
  }) {
    final _AuthFields auth = _resolveAuthFields(
      openid: openid,
      accessToken: accessToken,
      appid: appid,
    );
    final String resolvedAppId = auth.appid.isEmpty ? _defaultAppId : auth.appid;
    return "appid=$resolvedAppId; openid=${auth.openid}; acctype=qc; access_token=${auth.accessToken}";
  }

  Future<RemoteUserInfo?> fetchUserInfo({
    required String openid,
    required String accessToken,
  }) async {
    final String cookie = buildCookie(openid: openid, accessToken: accessToken);
    try {
      final Map<String, dynamic> data = await _postOfficialApi(
        cookie: cookie,
        method: "user.info",
        param: const <String, dynamic>{"seasonID": 1},
        easUrl: _recordPageReferer,
      );
      final Map<String, dynamic> payload =
          _toMap(data["data"]).isNotEmpty ? _toMap(data["data"]) : data;
      final String uin =
          _firstText(payload, const <String>["uin", "sUin", "iUin", "roleUin"]);
      if (uin.isEmpty) return null;
      return RemoteUserInfo(
        uin: uin,
        nickname: _decodeText(_firstText(
            payload, const <String>["nickname", "sNickName", "name", "nick"])),
        avatar: _firstText(
            payload, const <String>["avatar", "avatarUrl", "headUrl"]),
      );
    } catch (_) {
      return null;
    }
  }

  Future<StatsData> fetchStats({
    required String openid,
    required String accessToken,
  }) async {
    final String cookie = buildCookie(openid: openid, accessToken: accessToken);

    Map<String, dynamic> configData = <String, dynamic>{};
    try {
      configData = await _postOfficialApi(
        cookie: cookie,
        method: "center.config.list",
        param: const <String, dynamic>{"seasonID": 1, "configType": "all"},
        easUrl: _recordPageReferer,
      );
    } catch (_) {
      configData = <String, dynamic>{};
    }
    final Map<String, String> mapNameById = _buildMapNameById(configData);
    final Map<String, String> mapIconById = _buildMapIconById(configData);
    final Map<String, String> difficultyNameById =
        _buildDifficultyNameById(configData);

    final List<BattleRecord> games = <BattleRecord>[];
    final List<BattleRecord> targetGames = <BattleRecord>[];
    const int perPage = 10;
    const int maxRecentGames = 100;
    const int maxTargetGames = 100;
    for (int page = 1; page <= 30; page++) {
      if (page > 1) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
      Map<String, dynamic> pageData = <String, dynamic>{};
      try {
        pageData = await _postOfficialApi(
          cookie: cookie,
          method: "center.user.game.list",
          param: <String, dynamic>{
            "seasonID": 1,
            "page": page,
            "limit": perPage,
          },
          easUrl: _recordPageReferer,
        );
      } catch (_) {
        break;
      }
      final List<dynamic> list = pageData["gameList"] is List
          ? pageData["gameList"] as List<dynamic>
          : <dynamic>[];
      if (list.isEmpty) break;
      final List<BattleRecord> pageRecords = list
          .whereType<Map>()
          .map((Map e) => _recordFromMap(
                _toMap(e),
                source: "官方",
                mapNameById: mapNameById,
                difficultyNameById: difficultyNameById,
              ))
          .toList();
      for (final BattleRecord record in pageRecords) {
        if (games.length < maxRecentGames) {
          games.add(record);
        }
        if (_isTargetMode(record.modeName) && targetGames.length < maxTargetGames) {
          targetGames.add(record);
        }
      }
      if (games.length >= maxRecentGames && targetGames.length >= maxTargetGames) {
        break;
      }
    }

    Map<String, dynamic> summary = <String, dynamic>{};
    try {
      summary = await _postOfficialApi(
        cookie: cookie,
        method: "center.user.stats",
        param: const <String, dynamic>{"seasonID": 1},
        easUrl: _recordPageReferer,
      );
    } catch (_) {
      summary = <String, dynamic>{};
    }

    int zombieFromGames = 0;
    int towerFromGames = 0;
    int mechaFromGames = 0;
    int timehuntFromGames = 0;
    int totalDurationSeconds = 0;
    for (final BattleRecord g in games) {
      final String category = _modeCategory(g.modeName);
      if (category == "tower") {
        towerFromGames++;
      } else if (category == "mecha") {
        mechaFromGames++;
      } else if (category == "timehunt") {
        timehuntFromGames++;
      } else if (category == "zombie") {
        zombieFromGames++;
      }
      totalDurationSeconds += g.durationSeconds;
    }

    final int zombieTotal = _extractSummaryNumber(summary, <RegExp>[
      RegExp(r"huntgamecount", caseSensitive: false),
      RegExp(r"僵尸.*场次"),
      RegExp(r"zombie", caseSensitive: false),
      RegExp(r"hunter", caseSensitive: false),
      RegExp(r"pve", caseSensitive: false),
    ], zombieFromGames);
    final int towerTotal = _extractSummaryNumber(summary, <RegExp>[
      RegExp(r"towergamecount", caseSensitive: false),
      RegExp(r"塔防.*场次"),
      RegExp(r"tower", caseSensitive: false),
    ], towerFromGames);
    final int mechaTotal = _extractSummaryNumber(summary, <RegExp>[
      RegExp(r"mechagamecount", caseSensitive: false),
      RegExp(r"rankgamecount", caseSensitive: false),
      RegExp(r"机甲.*场次"),
      RegExp(r"排位.*场次"),
      RegExp(r"rank", caseSensitive: false),
      RegExp(r"mecha", caseSensitive: false),
    ], mechaFromGames);
    final int timehuntTotal = _extractSummaryNumber(summary, <RegExp>[
      RegExp(r"timehuntgamecount", caseSensitive: false),
      RegExp(r"时空.*场次"),
      RegExp(r"追猎.*场次"),
      RegExp(r"timehunt", caseSensitive: false),
      RegExp(r"hunt", caseSensitive: false),
    ], timehuntFromGames);

    final int playtimeRaw = _extractSummaryNumber(summary, <RegExp>[
      RegExp(r"playtime", caseSensitive: false),
      RegExp(r"在线.*时长"),
      RegExp(r"online.*time", caseSensitive: false),
      RegExp(r"play.*time", caseSensitive: false),
      RegExp(r"hour", caseSensitive: false),
    ], 0);
    final int onlineHours = playtimeRaw > 0
        ? (playtimeRaw >= 60 ? playtimeRaw ~/ 60 : playtimeRaw)
        : (totalDurationSeconds > 0 ? totalDurationSeconds ~/ 3600 : 0);

    int recentWins = 0;
    int recentTotalScore = 0;
    for (final BattleRecord g in targetGames) {
      if (g.isWin) recentWins++;
      recentTotalScore += g.score;
    }
    final double recentWinRate =
        targetGames.isEmpty ? 0 : (recentWins / targetGames.length) * 100;
    final int recentAvgScore =
        targetGames.isEmpty ? 0 : (recentTotalScore ~/ targetGames.length);

    final OverviewStats overview = OverviewStats(
      totalGames: zombieTotal,
      winRate: towerTotal.toDouble(),
      avgScore: mechaTotal,
      totalDamage: timehuntTotal,
      totalWin: onlineHours,
      totalLoss: targetGames.length,
      recentGames: targetGames.length,
      recentWinRate: double.parse(recentWinRate.toStringAsFixed(1)),
      recentAvgScore: recentAvgScore,
    );

    final Map<String, List<int>> modeMap = <String, List<int>>{};
    for (final BattleRecord g in games) {
      final String code = _modeCategory(g.modeName);
      String category = "";
      if (code == "zombie") {
        category = "僵尸猎场";
      } else if (code == "tower") {
        category = "塔防";
      } else if (code == "timehunt") {
        category = "时空追猎";
      } else if (code == "mecha") {
        category = "机甲排位";
      }

      if (category.isNotEmpty) {
        modeMap.putIfAbsent(category, () => <int>[0, 0, 0]);
        modeMap[category]![0]++;
        if (g.isWin) {
          modeMap[category]![1]++;
        } else {
          modeMap[category]![2]++;
        }
      }
    }
    final List<ModeStatsEntry> modeStats =
        modeMap.entries.map((MapEntry<String, List<int>> e) {
      return ModeStatsEntry(
        modeName: e.key,
        games: e.value[0],
        wins: e.value[1],
        losses: e.value[2],
      );
    }).toList()
          ..sort(
              (ModeStatsEntry a, ModeStatsEntry b) => b.games.compareTo(a.games));

    final Map<String, _MapAgg> mapGroups = <String, _MapAgg>{};
    for (final BattleRecord g in targetGames) {
      final String mapName = g.mapName.trim().isEmpty ? "未知地图" : g.mapName.trim();
      final String mapIdKey = g.mapId > 0 ? "${g.mapId}" : "";
      final String mapKey = mapIdKey.isNotEmpty ? "id:$mapIdKey" : "name:$mapName";
      final String iconUrl =
          mapIdKey.isEmpty ? "" : (mapIconById[mapIdKey] ?? "");
      final _MapAgg agg = mapGroups.putIfAbsent(
        mapKey,
        () => _MapAgg(
          mapName: mapName,
          mapId: mapIdKey,
          iconUrl: iconUrl,
        ),
      );
      if (agg.mapName == "未知地图" && mapName != "未知地图") {
        agg.mapName = mapName;
      }
      if (agg.iconUrl.isEmpty && iconUrl.isNotEmpty) {
        agg.iconUrl = iconUrl;
      }
      agg.total += 1;
      if (g.isWin) agg.win += 1;
      final String diffName =
          g.difficultyName.trim().isEmpty ? "未知难度" : g.difficultyName.trim();
      final _DiffAgg diffAgg = agg.difficulty.putIfAbsent(
        diffName,
        () => _DiffAgg(diffName: diffName),
      );
      diffAgg.total += 1;
      if (g.isWin) diffAgg.win += 1;
    }
    final List<MapStatsEntry> mapStats = mapGroups.values.map((_MapAgg e) {
      final double rate = e.total > 0 ? (e.win / e.total) * 100 : 0.0;
      final List<MapDifficultyEntry> details =
          e.difficulty.values.map((_DiffAgg d) {
        final double diffRate = d.total > 0 ? (d.win / d.total) * 100 : 0.0;
        return MapDifficultyEntry(
          diffName: d.diffName,
          games: d.total,
          winCount: d.win,
          winRate: double.parse(diffRate.toStringAsFixed(1)),
        );
      }).toList()
            ..sort((MapDifficultyEntry a, MapDifficultyEntry b) =>
                b.games.compareTo(a.games));
      return MapStatsEntry(
        mapName: e.mapName,
        games: e.total,
        winCount: e.win,
        winRate: double.parse(rate.toStringAsFixed(1)),
        iconUrl: e.iconUrl,
        difficulties: details,
      );
    }).toList()
      ..sort((MapStatsEntry a, MapStatsEntry b) => b.games.compareTo(a.games));

    final List<FragmentProgress> fragments = <FragmentProgress>[];
    try {
      final Map<String, dynamic> homeData = await _postOfficialApi(
        cookie: cookie,
        method: "collection.home",
        param: const <String, dynamic>{"seasonID": 1, "limit": 8},
        easUrl: _handbookPageReferer,
      );
      final List<dynamic> source = homeData["home"] is List
          ? homeData["home"] as List<dynamic>
          : homeData["weaponList"] is List
              ? homeData["weaponList"] as List<dynamic>
              : <dynamic>[];
      for (final dynamic item in source) {
        if (item is! Map) continue;
        final Map<String, dynamic> m = _toMap(item);
        final dynamic prog = m["itemProgress"];
        final bool hasProgress = prog is Map
            ? prog.isNotEmpty
            : (prog is List ? prog.isNotEmpty : prog != null);
        if (!hasProgress) continue;

        final String name = _decodeText(_extractCollectionName(m));
        final _FragmentCountInfo countInfo = _extractFragmentCountInfo(m);
        final String iconUrl = _resolveImageUrl(_extractCollectionIcon(m));
        fragments.add(FragmentProgress(
          name: name.isEmpty ? "未知碎片" : name,
          current: countInfo.current,
          target: countInfo.target,
          iconUrl: iconUrl,
        ));
      }
    } catch (_) {
      // ignore fragment errors
    }

    return StatsData(
      overview: overview,
      modeStats: modeStats,
      mapStats: mapStats,
      fragments: fragments,
    );
  }

  Future<HistoryPageData> fetchHistoryPage({
    required String openid,
    required String accessToken,
    int page = 1,
    int limit = 30,
    String modeType = "",
  }) async {
    final String cookie = buildCookie(openid: openid, accessToken: accessToken);
    final Map<String, dynamic> query = <String, dynamic>{
      "seasonID": 1,
      "page": page > 0 ? page : 1,
      "limit": limit > 0 ? limit : 30,
    };
    if (RegExp(r"^\d+$").hasMatch(modeType.trim())) {
      query["modeType"] = modeType.trim();
    }
    final Map<String, dynamic> data = await _postOfficialApi(
      cookie: cookie,
      method: "center.user.game.list",
      param: query,
      easUrl: _recordPageReferer,
    );
    Map<String, dynamic> configData = <String, dynamic>{};
    try {
      configData = await _postOfficialApi(
        cookie: cookie,
        method: "center.config.list",
        param: const <String, dynamic>{"seasonID": 1, "configType": "all"},
        easUrl: _recordPageReferer,
      );
    } catch (_) {
      configData = <String, dynamic>{};
    }
    final Map<String, String> mapNameById = _buildMapNameById(configData);
    final Map<String, String> difficultyNameById =
        _buildDifficultyNameById(configData);
    final List<dynamic> list = data["gameList"] is List
        ? data["gameList"] as List<dynamic>
        : <dynamic>[];
    final List<BattleRecord> records = list
        .whereType<Map>()
        .map((Map e) => _recordFromMap(
              _toMap(e),
              source: "官方",
              mapNameById: mapNameById,
              difficultyNameById: difficultyNameById,
            ))
        .toList();
    final int totalPagesRaw = _toInt(data["totalPage"] ??
        data["pageCount"] ??
        data["totalPages"] ??
        data["lastPage"]);
    final int totalCountRaw =
        _toInt(data["totalCount"] ?? data["count"] ?? data["allCount"]);
    final int safeLimit = limit > 0 ? limit : 30;
    final int computedPages =
        totalCountRaw > 0 ? ((totalCountRaw + safeLimit - 1) ~/ safeLimit) : 0;
    final int currentPage = page > 0 ? page : 1;
    final bool inferredHasMore = records.length >= safeLimit;
    final int inferredPages =
        inferredHasMore ? (currentPage + 1) : currentPage;
    final int totalPages = totalPagesRaw > 0
        ? totalPagesRaw
        : (computedPages > 0 ? computedPages : max(1, inferredPages));
    final Map<String, String> modeOptions = _buildModeOptions(configData);
    final Map<String, String> difficultyOptions =
        _buildDifficultyOptions(configData, records);
    final Map<String, String> mapOptions =
        _buildMapFilterOptions(configData, records);
    return HistoryPageData(
      records: records,
      page: page > 0 ? page : 1,
      limit: safeLimit,
      totalPages: totalPages,
      totalCount: totalCountRaw,
      modeOptions: modeOptions,
      difficultyOptions: difficultyOptions,
      mapOptions: mapOptions,
    );
  }

  Future<List<BattleRecord>> fetchHistory({
    required String openid,
    required String accessToken,
    int page = 1,
    int limit = 30,
  }) async {
    final HistoryPageData paged = await fetchHistoryPage(
      openid: openid,
      accessToken: accessToken,
      page: page,
      limit: limit,
    );
    return paged.records;
  }

  Future<CollectionData> fetchCollection({
    required String openid,
    required String accessToken,
  }) async {
    final String cookie = buildCookie(openid: openid, accessToken: accessToken);

    final Future<List<CollectionItem>> homeFuture = _fetchHomeCollection(cookie);
    final Future<List<CollectionItem>> weaponsFuture = _postOfficialApi(
      cookie: cookie,
      method: "collection.weapon.list",
      param: const <String, dynamic>{"seasonID": 1, "queryTime": true},
      easUrl: _handbookPageReferer,
    ).then((Map<String, dynamic> value) =>
        _parseCollectionList(value["list"], "weapon"));
    final Future<List<CollectionItem>> trapsFuture = _postOfficialApi(
      cookie: cookie,
      method: "collection.trap.list",
      param: const <String, dynamic>{"seasonID": 1},
      easUrl: _handbookPageReferer,
    ).then((Map<String, dynamic> value) =>
        _parseCollectionList(value["list"], "trap"));
    final Future<List<CollectionItem>> pluginsFuture = _postOfficialApi(
      cookie: cookie,
      method: "collection.plugin.list",
      param: const <String, dynamic>{"seasonID": 1},
      easUrl: _handbookPageReferer,
    ).then((Map<String, dynamic> value) =>
        _parseCollectionList(value["list"], "plugin"));

    final List<dynamic> result = await Future.wait<dynamic>(<Future<dynamic>>[
      homeFuture,
      weaponsFuture,
      trapsFuture,
      pluginsFuture,
    ]);

    return CollectionData(
      home: result[0] as List<CollectionItem>,
      weapons: result[1] as List<CollectionItem>,
      traps: result[2] as List<CollectionItem>,
      plugins: result[3] as List<CollectionItem>,
    );
  }

  Future<Map<String, dynamic>> fetchRoomDetail({
    required String openid,
    required String accessToken,
    required String roomId,
  }) async {
    final String cookie = buildCookie(openid: openid, accessToken: accessToken);
    final List<dynamic> result = await Future.wait<dynamic>(<Future<dynamic>>[
      _postOfficialApi(
        cookie: cookie,
        method: "center.game.detail",
        param: <String, dynamic>{"seasonID": 1, "roomID": roomId},
        easUrl: _recordInfoPageReferer,
      ),
      _postOfficialApi(
        cookie: cookie,
        method: "center.config.list",
        param: const <String, dynamic>{"seasonID": 1},
        easUrl: _recordPageReferer,
      ).catchError((_) => <String, dynamic>{}),
    ]);
    final Map<String, dynamic> detail = result[0] as Map<String, dynamic>;
    final Map<String, dynamic> config = result[1] as Map<String, dynamic>;
    return <String, dynamic>{
      ...detail,
      "partitionAreaMap": _buildPartitionAreaNameMap(config),
    };
  }

  Future<List<CollectionItem>> _fetchHomeCollection(String cookie) async {
    try {
      final Map<String, dynamic> data = await _postOfficialApi(
        cookie: cookie,
        method: "collection.home",
        param: const <String, dynamic>{"seasonID": 1, "limit": 8},
        easUrl: _handbookPageReferer,
      );
      final List<dynamic> homeList = data["weaponList"] is List
          ? data["weaponList"] as List<dynamic>
          : data["home"] is List
              ? data["home"] as List<dynamic>
              : <dynamic>[];
      final List<dynamic> validList = homeList.where((dynamic e) {
        if (e is! Map) return false;
        final dynamic prog = e["itemProgress"];
        if (prog is Map) return prog.isNotEmpty;
        if (prog is List) return prog.isNotEmpty;
        return prog != null;
      }).toList();
      return _parseCollectionList(validList, "home");
    } catch (_) {
      return const <CollectionItem>[];
    }
  }

  Future<Map<String, dynamic>> _postOfficialApi({
    required String cookie,
    required String method,
    required Map<String, dynamic> param,
    required String easUrl,
  }) async {
    final Map<String, String> body = <String, String>{
      "iChartId": "430662",
      "iSubChartId": "430662",
      "sIdeToken": "NoOapI",
      "eas_url": easUrl,
      "method": method,
      "from_source": "2",
      "param": jsonEncode(param),
    };

    final Map<String, String> headers = <String, String>{
      "Host": "comm.ams.game.qq.com",
      "Content-Type": "application/x-www-form-urlencoded",
      "Accept": "*/*",
      "Accept-Language": "zh-CN,zh;q=0.9",
      "User-Agent": _miniProgramUserAgent,
      "Referer":
          "https://servicewechat.com/wx4e8cbe4fb0eca54c/13/page-frame.html",
      "xweb_xhr": "1",
      "Cookie": cookie,
    };

    final String bodyString = body.entries
        .map((MapEntry<String, String> e) =>
            "${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}")
        .join("&");

    _logRequest(
      method: "POST",
      url: _officialDataApi,
      headers: headers,
      body: body,
    );
    final http.Response response = await _client.post(
      Uri.parse(_officialDataApi),
      headers: headers,
      body: bodyString,
    );
    final String responseBody = _decodeBody(response);
    _logResponse(
      method: "POST",
      url: _officialDataApi,
      response: response,
      bodyText: responseBody,
    );

    if (response.statusCode == 401) {
      throw ApiUnauthorizedException("官方接口鉴权失败: HTTP 401");
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception("官方接口请求失败: HTTP ${response.statusCode}");
    }
    final Map<String, dynamic> decoded = _decodeJsonMap(responseBody);
    if (_toInt(decoded["iRet"]) != 0) {
      throw Exception("${decoded["sMsg"] ?? "请求失败"}");
    }

    final Map<String, dynamic> jData = _toMap(decoded["jData"]);
    final Map<String, dynamic> d1 = _toMap(jData["data"]);
    final Map<String, dynamic> d2 = _toMap(d1["data"]);
    return d2;
  }

  List<CollectionItem> _parseCollectionList(dynamic raw, String type) {
    if (raw is! List) return const <CollectionItem>[];
    return raw
        .whereType<Map>()
        .map((Map e) => _toMap(e))
        .map((Map<String, dynamic> item) {
          final String name = _decodeText(_extractCollectionName(item));
          final String fallbackName = type == "trap"
              ? "陷阱"
              : type == "plugin"
                  ? "插件"
                  : type == "home"
                      ? "家园道具"
                      : "道具";
          final String quality = _decodeText(
            _firstText(item, const <String>["quality", "rare", "level", "grade"]),
          );
          final String iconRaw = _extractCollectionIcon(item);
          return CollectionItem(
            name: name.isEmpty ? fallbackName : name,
            type: type,
            owned: _toBool(item["owned"]) ||
                _toBool(item["iHas"]) ||
                _toInt(item["iOwned"]) == 1 ||
                _toInt(item["has"]) == 1 ||
                _toBool(item["isOwned"]),
            quality: quality.isEmpty ? "普通" : quality,
            iconUrl: _resolveImageUrl(iconRaw),
          );
        })
        .toList();
  }

  String _extractCollectionName(Map<String, dynamic> item) {
    final String direct = _firstText(item, const <String>[
      "name",
      "weaponName",
      "trapName",
      "pluginName",
      "itemName",
      "sName",
      "title",
      "displayName",
      "itemTitle",
    ]);
    if (direct.isNotEmpty) return direct;

    const List<String> nestedKeys = <String>[
      "itemInfo",
      "weaponInfo",
      "trapInfo",
      "pluginInfo",
      "detail",
      "data",
      "baseInfo",
    ];
    for (final String key in nestedKeys) {
      final Map<String, dynamic> nested = _toMap(item[key]);
      if (nested.isEmpty) continue;
      final String name = _firstText(nested, const <String>[
        "name",
        "weaponName",
        "trapName",
        "pluginName",
        "itemName",
        "sName",
        "title",
        "displayName",
        "itemTitle",
      ]);
      if (name.isNotEmpty) return name;
    }
    return "";
  }

  String _extractCollectionIcon(Map<String, dynamic> item) {
    final String direct = _firstText(item, const <String>[
      "icon",
      "sIcon",
      "pic",
      "img",
      "image",
      "weaponIcon",
      "trapIcon",
      "pluginIcon",
      "sImg",
      "sPic",
      "imgUrl",
      "picUrl",
      "sBgImg",
      "bgImg",
    ]);
    if (direct.isNotEmpty) return direct;

    const List<String> nestedKeys = <String>[
      "itemInfo",
      "weaponInfo",
      "trapInfo",
      "pluginInfo",
      "detail",
      "data",
      "baseInfo",
    ];
    for (final String key in nestedKeys) {
      final Map<String, dynamic> nested = _toMap(item[key]);
      if (nested.isEmpty) continue;
      final String icon = _firstText(nested, const <String>[
        "icon",
        "sIcon",
        "pic",
        "img",
        "image",
        "weaponIcon",
        "trapIcon",
        "pluginIcon",
        "sImg",
        "sPic",
        "imgUrl",
        "picUrl",
        "sBgImg",
        "bgImg",
      ]);
      if (icon.isNotEmpty) return icon;
    }
    return "";
  }

  _FragmentCountInfo _extractFragmentCountInfo(Map<String, dynamic> item) {
    final Map<String, dynamic> progress =
        _toMap(_parseJsonIfString(item["itemProgress"]));
    final Map<String, dynamic> merged = <String, dynamic>{...progress, ...item};

    final List<RegExp> currentKeyPatterns = <RegExp>[
      RegExp(r"cur|current|num|piece|chip|progress|owned|have|count",
          caseSensitive: false),
    ];
    final List<RegExp> targetKeyPatterns = <RegExp>[
      RegExp(r"need|max|total|target|full|limit|require", caseSensitive: false),
    ];

    int current = _firstPositiveInt(<dynamic>[
      item["itemProgressCurrent"],
      item["currentNum"],
      item["current"],
      item["curNum"],
      item["weaponNum"],
      item["pieceNum"],
      item["iPieceNum"],
      item["chipNum"],
      item["progressNum"],
      item["num"],
      item["iNum"],
      progress["current"],
      progress["cur"],
      progress["value"],
      progress["num"],
      item["count"],
    ]);
    if (current <= 0) {
      current = _findNumericByPatterns(merged, currentKeyPatterns);
    }

    int target = _firstPositiveInt(<dynamic>[
      item["itemProgressRequired"],
      item["totalNum"],
      item["needNum"],
      item["targetNum"],
      item["maxNum"],
      item["iNeedNum"],
      item["iTotal"],
      item["total"],
      item["target"],
      item["need"],
      progress["required"],
      progress["need"],
      progress["target"],
      progress["total"],
      progress["max"],
    ]);
    if (target <= 0) {
      target = _findNumericByPatterns(merged, targetKeyPatterns);
    }
    if (target <= 0) {
      target = current > 0 ? (current > 100 ? current : 100) : 100;
    }

    final bool owned = _toBool(item["owned"]) ||
        _toBool(item["isOwned"]) ||
        _toInt(item["iOwned"]) == 1 ||
        _toInt(item["has"]) == 1 ||
        _toBool(progress["owned"]) ||
        _toBool(progress["isOwned"]);
    if (owned && current <= 0) {
      current = target;
    }
    return _FragmentCountInfo(current: current, target: target);
  }

  int _firstPositiveInt(List<dynamic> values) {
    for (final dynamic value in values) {
      final int n = _toInt(value);
      if (n > 0) return n;
    }
    return 0;
  }

  int _findNumericByPatterns(
      Map<String, dynamic> source, List<RegExp> patterns) {
    for (final MapEntry<String, dynamic> entry in source.entries) {
      final String key = entry.key.toLowerCase();
      if (!patterns.any((RegExp p) => p.hasMatch(key))) continue;
      final int value = _toInt(entry.value);
      if (value > 0) return value;
    }
    return 0;
  }

  BattleRecord _recordFromMap(
    Map<String, dynamic> item, {
    required String source,
    Map<String, String> mapNameById = const <String, String>{},
    Map<String, String> difficultyNameById = const <String, String>{},
  }) {
    final String roomId = _firstText(item, const <String>[
      "roomID",
      "DsRoomId",
      "dsRoomId",
      "sRoomID",
      "roomId",
      "iRoomId",
      "id",
    ]);
    final bool isWin = _toInt(item["iIsWin"]) == 1 || _toBool(item["isWin"]);
    final int modeType = _toInt(item["iModeType"] ??
        item["modeType"] ??
        item["iGameMode"] ??
        item["gameMode"] ??
        item["iMode"]);
    final String directModeName = _decodeText(_firstText(
        item, const <String>["modeName", "sModeName", "sTypeName", "mode"]));
    final String modeName = _normalizeModeName(
      directModeName,
      modeType: modeType,
    );
    final String diffId = _firstText(item, const <String>[
      "iSubModeType",
      "subModeType",
      "iDiffId",
      "diffId",
      "iDifficulty",
      "difficulty",
    ]);
    final String mapIdText = _firstText(item, const <String>[
      "iMapId",
      "mapId",
      "mapID",
    ]);
    final String directDiffName = _normalizeDifficultyName(_decodeText(
        _firstText(item, const <String>["diffName", "difficultyName", "difficulty"])));
    final String mappedDiffName =
        _normalizeDifficultyName(difficultyNameById[diffId] ?? "");
    final bool directDiffLooksCode = RegExp(r"^\d+$").hasMatch(directDiffName);
    final String diffName = directDiffName.isNotEmpty &&
            directDiffName != "未知难度" &&
            !directDiffLooksCode
        ? directDiffName
        : (mappedDiffName.isNotEmpty ? mappedDiffName : "未知难度");
    final String directMapName = _decodeText(
        _firstText(item, const <String>["mapName", "sMapName", "map"]));
    final String mappedMapName = mapNameById[mapIdText] ?? "";
    final bool directMapLooksCode = RegExp(r"^\d+$").hasMatch(directMapName);
    final String mapName =
        directMapName.isNotEmpty &&
                directMapName != "未知地图" &&
                !directMapLooksCode
            ? directMapName
            : (mappedMapName.isNotEmpty ? mappedMapName : "未知地图");
    return BattleRecord(
      roomId: roomId.isEmpty ? "-" : roomId,
      mapName: mapName,
      modeName: modeName.isEmpty ? "未知模式" : modeName,
      difficultyName: diffName,
      score: _toInt(item["iScore"]),
      isWin: isWin,
      timeText: _formatTime(_firstText(item,
          const <String>["dtEventTime", "eventTime", "createTime", "time"])),
      source: source,
      sourceType: source == "本地" ? "json-transfer" : "official-sync",
      mapId: _toInt(item["iMapId"] ?? item["mapId"] ?? item["mapID"]),
      durationSeconds: _toInt(item["iDuration"] ?? item["duration"]),
      startTimeText:
          _firstText(item, const <String>["dtGameStartTime", "startTime"]),
      eventTimeRaw:
          _firstText(item, const <String>["dtEventTime", "eventTime", "time"]),
      bossDamage: _toInt(item["iBossDamage"] ??
          item["bossDamage"] ??
          item["iDamage"] ??
          item["iTotalDamage"] ??
          item["damage"] ??
          item["totalDamage"]),
      modeType: modeType,
    );
  }

  Map<String, String> _buildModeOptions(Map<String, dynamic> configData) {
    final Map<String, String> out = <String, String>{
      "65": "排位",
      "134": "僵尸猎场",
      "136": "时空追猎",
      "139": "塔防",
    };
    final Map<String, dynamic> root = _configRoot(configData);
    final dynamic modeInfoRaw = root["modeInfo"] ?? root["modeTypeInfo"];
    final dynamic parsed = _parseJsonIfString(modeInfoRaw);
    if (parsed is Map) {
      final Map<String, dynamic> map = _toMap(parsed);
      map.forEach((String key, dynamic value) {
        final String id = key.trim();
        if (id.isEmpty) return;
        final Map<String, dynamic> node = _toMap(_parseJsonIfString(value));
        final String modeName = _normalizeModeName(
          _decodeText(_firstText(
            node,
            const <String>["modeName", "name", "title", "displayName"],
          )),
          modeType: int.tryParse(id) ?? 0,
        );
        if (modeName.isNotEmpty) {
          out[id] = modeName;
        }
      });
    }
    return out;
  }

  Map<String, String> _buildDifficultyOptions(
      Map<String, dynamic> configData, List<BattleRecord> records) {
    final Set<String> set = <String>{};
    final Map<String, String> byId = _buildDifficultyNameById(configData);
    set.addAll(byId.values.where((String e) => e.trim().isNotEmpty));
    for (final BattleRecord r in records) {
      final String name = r.difficultyName.trim();
      if (name.isNotEmpty) {
        set.add(name);
      }
    }
    final List<String> all = set.toList()..sort();
    final Map<String, String> out = <String, String>{};
    for (final String item in all) {
      out[item] = item;
    }
    return out;
  }

  Map<String, String> _buildMapFilterOptions(
      Map<String, dynamic> configData, List<BattleRecord> records) {
    final Map<String, String> out = <String, String>{};
    final Map<String, dynamic> root = _configRoot(configData);
    final dynamic parsed = _parseJsonIfString(root["mapInfo"]);

    void consumeNode(Map<String, dynamic> node) {
      final String mapName = _decodeText(_firstText(node, const <String>[
        "mapName",
        "sMapName",
        "name",
        "title",
        "displayName",
      ]));
      if (mapName.trim().isEmpty) return;
      final int modeType = _toInt(
        node["modeType"] ??
            node["iModeType"] ??
            node["iGameMode"] ??
            node["gameMode"] ??
            node["modeId"],
      );
      final String rawModeName = _decodeText(_firstText(node, const <String>[
        "modeName",
        "sModeName",
        "mode",
        "modeTypeName",
        "gameModeName",
      ]));
      final String modeName =
          _normalizeModeName(rawModeName, modeType: modeType).trim();
      final String key = _buildLocalMapFilterKey(mapName, modeName);
      out.putIfAbsent(key, () => _formatLocalMapFilterLabel(mapName, modeName));
    }

    if (parsed is Map) {
      final Map<String, dynamic> map = _toMap(parsed);
      map.forEach((String _, dynamic value) {
        final Map<String, dynamic> node = _toMap(_parseJsonIfString(value));
        if (node.isEmpty) return;
        consumeNode(node);
      });
    } else if (parsed is List) {
      for (final dynamic value in parsed) {
        final Map<String, dynamic> node = _toMap(_parseJsonIfString(value));
        if (node.isEmpty) continue;
        consumeNode(node);
      }
    }

    for (final BattleRecord record in records) {
      final String mapName = record.mapName.trim();
      if (mapName.isEmpty) continue;
      final String modeName = record.modeName.trim();
      final String key = _buildLocalMapFilterKey(mapName, modeName);
      out.putIfAbsent(key, () => _formatLocalMapFilterLabel(mapName, modeName));
    }
    return out;
  }

  String _buildLocalMapFilterKey(String mapName, String modeName) {
    final String normalizedMapName = mapName.trim();
    final String normalizedModeName = modeName.trim();
    return "${normalizedMapName}__mode__$normalizedModeName";
  }

  String _formatLocalMapFilterLabel(String mapName, String modeName) {
    final String normalizedMapName =
        mapName.trim().isEmpty ? "未知地图" : mapName.trim();
    final String normalizedModeName = modeName.trim();
    if (normalizedModeName.isEmpty) return normalizedMapName;
    return "$normalizedMapName（$normalizedModeName）";
  }

  bool _isTargetMode(String modeName) {
    return _modeCategory(modeName).isNotEmpty;
  }

  String _modeCategory(String modeName) {
    final String raw = modeName.toLowerCase();
    if (raw.contains("塔防") || raw.contains("濉旈槻")) return "tower";
    if (raw.contains("排位") || raw.contains("机甲")) return "mecha";
    if (raw.contains("时空") ||
        raw.contains("追捕") ||
        raw.contains("追猎") ||
        raw.contains("鏃剁┖") ||
        raw.contains("杩芥崟") ||
        raw.contains("杩界寧")) {
      return "timehunt";
    }
    if (raw.contains("猎场") ||
        raw.contains("僵尸") ||
        raw.contains("鐚庡満") ||
        raw.contains("鍍靛案")) {
      return "zombie";
    }
    return "";
  }

  String _modeNameFromType(int modeType) {
    if (modeType == 65) return "排位";
    if (modeType == 134) return "僵尸猎场";
    if (modeType == 136) return "时空追猎";
    if (modeType == 139) return "塔防";
    return "";
  }

  String _normalizeDifficultyName(String value) {
    final String raw = value.trim();
    if (raw.isEmpty) return "";
    if (raw.contains("炼狱")) return "炼狱";
    if (raw == "折磨" ||
        RegExp(r"折磨\s*(?:I|1|Ⅰ)$", caseSensitive: false).hasMatch(raw) ||
        RegExp(r"折磨\s*(?:I|1|Ⅰ)\b", caseSensitive: false).hasMatch(raw)) {
      return "折磨I";
    }
    return raw;
  }

  String _normalizeModeName(String rawMode, {required int modeType}) {
    final String mapped = _modeNameFromType(modeType);
    final String raw = rawMode.trim();
    if (raw.isEmpty) return mapped;
    final bool looksMojibake = raw.contains("鐚") ||
        raw.contains("鍍") ||
        raw.contains("濉") ||
        raw.contains("鏃") ||
        raw.contains("杩");
    if (mapped.isEmpty && looksMojibake) {
      final String category = _modeCategory(raw);
      if (category == "tower") return "塔防";
      if (category == "mecha") return "排位";
      if (category == "timehunt") return "时空追猎";
      if (category == "zombie") return "僵尸猎场";
    }
    if (looksMojibake && mapped.isNotEmpty) return mapped;
    return raw;
  }

  int _extractSummaryNumber(
      Map<String, dynamic> summary, List<RegExp> patterns, int fallback) {
    final List<_NumericEntry> entries = _flattenNumericEntries(summary);
    for (final _NumericEntry entry in entries) {
      if (patterns.any((RegExp reg) => reg.hasMatch(entry.key))) {
        return entry.value;
      }
    }
    return fallback;
  }

  List<_NumericEntry> _flattenNumericEntries(dynamic value,
      {String prefix = "", int depth = 0, int maxDepth = 3}) {
    if (value == null || depth > maxDepth) return const <_NumericEntry>[];
    final List<_NumericEntry> out = <_NumericEntry>[];
    if (value is Map) {
      final Map<dynamic, dynamic> map = Map<dynamic, dynamic>.from(value);
      map.forEach((dynamic key, dynamic child) {
        final String nextPrefix = prefix.isEmpty
            ? "${key ?? ""}".toLowerCase()
            : "$prefix.${"${key ?? ""}".toLowerCase()}";
        out.addAll(_flattenNumericEntries(
          child,
          prefix: nextPrefix,
          depth: depth + 1,
          maxDepth: maxDepth,
        ));
      });
      return out;
    }
    if (value is List) {
      for (int i = 0; i < value.length; i++) {
        out.addAll(_flattenNumericEntries(
          value[i],
          prefix: "$prefix[$i]",
          depth: depth + 1,
          maxDepth: maxDepth,
        ));
      }
      return out;
    }
    final int numeric = _toInt(value);
    if (numeric != 0 || "${value ?? ""}".trim() == "0") {
      out.add(_NumericEntry(key: prefix.toLowerCase(), value: numeric));
    }
    return out;
  }

  String _resolveImageUrl(String raw) {
    final String value = raw.trim();
    if (value.isEmpty) return "";
    if (value.startsWith("data:image/")) return value;
    if (RegExp(r"^https?://", caseSensitive: false).hasMatch(value)) {
      return value;
    }
    if (value.startsWith("//")) {
      return "https:$value";
    }
    final String base =
        _officialImageHost.endsWith("/") ? _officialImageHost : "$_officialImageHost/";
    if (value.startsWith("/")) {
      return "${base.substring(0, base.length - 1)}$value";
    }
    return "$base$value";
  }

  dynamic _parseJsonIfString(dynamic value) {
    if (value is! String) return value;
    final String text = value.trim();
    if (text.isEmpty) return value;
    final bool maybeJson = (text.startsWith("{") && text.endsWith("}")) ||
        (text.startsWith("[") && text.endsWith("]"));
    if (!maybeJson) return value;
    try {
      return jsonDecode(text);
    } catch (_) {
      return value;
    }
  }

  Map<String, dynamic> _configRoot(Map<String, dynamic> configData) {
    final dynamic rootRaw =
        configData["config"] is Map ? configData["config"] : configData;
    final dynamic parsed = _parseJsonIfString(rootRaw);
    return _toMap(parsed);
  }

  Map<String, String> _buildMapNameById(Map<String, dynamic> configData) {
    final Map<String, dynamic> root = _configRoot(configData);
    final dynamic parsed = _parseJsonIfString(root["mapInfo"]);
    final Map<String, String> out = <String, String>{};
    if (parsed is Map) {
      final Map<String, dynamic> map = _toMap(parsed);
      map.forEach((String key, dynamic value) {
        final String mapId = key.trim();
        if (mapId.isEmpty) return;
        final Map<String, dynamic> node = _toMap(_parseJsonIfString(value));
        final String mapName = _decodeText(_firstText(node, const <String>[
          "mapName",
          "sMapName",
          "name",
          "title",
          "displayName",
        ]));
        if (mapName.isNotEmpty) {
          out[mapId] = mapName;
        }
      });
    } else if (parsed is List) {
      for (final dynamic value in parsed) {
        final Map<String, dynamic> node = _toMap(_parseJsonIfString(value));
        final String mapId = _firstText(node, const <String>[
          "mapId",
          "iMapId",
          "id",
        ]);
        if (mapId.isEmpty) continue;
        final String mapName = _decodeText(_firstText(node, const <String>[
          "mapName",
          "sMapName",
          "name",
          "title",
          "displayName",
        ]));
        if (mapName.isNotEmpty) {
          out[mapId] = mapName;
        }
      }
    }
    return out;
  }

  Map<String, String> _buildMapIconById(Map<String, dynamic> configData) {
    final Map<String, dynamic> root = _configRoot(configData);
    final dynamic parsed = _parseJsonIfString(root["mapInfo"]);
    final Map<String, String> out = <String, String>{};
    if (parsed is Map) {
      final Map<String, dynamic> map = _toMap(parsed);
      map.forEach((String key, dynamic value) {
        final String mapId = key.trim();
        if (mapId.isEmpty) return;
        final Map<String, dynamic> node = _toMap(_parseJsonIfString(value));
        final String iconRaw = _firstText(node, const <String>[
          "bgImg",
          "sBgImg",
          "icon",
          "sIcon",
          "pic",
          "image",
          "img",
          "imgUrl",
          "picUrl",
          "mapBg",
          "cover",
        ]);
        final String iconUrl = _resolveImageUrl(iconRaw);
        if (iconUrl.isNotEmpty) {
          out[mapId] = iconUrl;
        }
      });
    } else if (parsed is List) {
      for (final dynamic value in parsed) {
        final Map<String, dynamic> node = _toMap(_parseJsonIfString(value));
        final String mapId = _firstText(node, const <String>[
          "mapId",
          "iMapId",
          "id",
        ]);
        if (mapId.isEmpty) continue;
        final String iconRaw = _firstText(node, const <String>[
          "bgImg",
          "sBgImg",
          "icon",
          "sIcon",
          "pic",
          "image",
          "img",
          "imgUrl",
          "picUrl",
          "mapBg",
          "cover",
        ]);
        final String iconUrl = _resolveImageUrl(iconRaw);
        if (iconUrl.isNotEmpty) {
          out[mapId] = iconUrl;
        }
      }
    }
    return out;
  }

  Map<String, String> _buildDifficultyNameById(Map<String, dynamic> configData) {
    final Map<String, dynamic> root = _configRoot(configData);
    final dynamic parsed = _parseJsonIfString(root["difficultyInfo"]);
    final Map<String, String> out = <String, String>{};
    if (parsed is Map) {
      final Map<String, dynamic> map = _toMap(parsed);
      map.forEach((String key, dynamic value) {
        final String diffId = key.trim();
        if (diffId.isEmpty) return;
        final Map<String, dynamic> node = _toMap(_parseJsonIfString(value));
        final String diffName = _normalizeDifficultyName(_decodeText(_firstText(
          node,
          const <String>[
            "diffName",
            "difficultyName",
            "name",
            "title",
            "displayName",
          ],
        )));
        if (diffName.isNotEmpty) {
          out[diffId] = diffName;
        }
      });
    } else if (parsed is List) {
      for (final dynamic value in parsed) {
        final Map<String, dynamic> node = _toMap(_parseJsonIfString(value));
        final String diffId = _firstText(node, const <String>[
          "diffId",
          "iDiffId",
          "id",
          "subModeType",
          "iSubModeType",
        ]);
        if (diffId.isEmpty) continue;
        final String diffName = _normalizeDifficultyName(_decodeText(_firstText(
          node,
          const <String>[
            "diffName",
            "difficultyName",
            "name",
            "title",
            "displayName",
          ],
        )));
        if (diffName.isNotEmpty) {
          out[diffId] = diffName;
        }
      }
    }
    return out;
  }

  Map<String, String> _buildPartitionAreaNameMap(Map<String, dynamic> configData) {
    final Map<String, dynamic> root = _configRoot(configData);
    final dynamic rawArea = root["huntingFieldPartitionArea"] ??
        root["huntingFielartitionArea"] ??
        root["huntingPartitionArea"];
    final dynamic parsed = _parseJsonIfString(rawArea);
    final Map<String, String> out = <String, String>{};
    if (parsed is List) {
      for (int i = 0; i < parsed.length; i++) {
        final dynamic item = parsed[i];
        if (item is! Map) continue;
        final Map<String, dynamic> node = _toMap(item);
        final String areaId =
            _firstText(node, const <String>["areaId", "iAreaId", "id"]);
        final String key = areaId.isEmpty ? "${i + 1}" : areaId;
        final String areaName = _decodeText(_firstText(node, const <String>[
          "areaName",
          "name",
          "partitionName",
          "displayName",
          "label"
        ]));
        out[key] = areaName.isEmpty ? "区域$key" : areaName;
      }
    } else if (parsed is Map) {
      final Map<String, dynamic> map = _toMap(parsed);
      map.forEach((String key, dynamic value) {
        final String areaId = key.trim();
        if (areaId.isEmpty) return;
        if (value is Map) {
          final Map<String, dynamic> node = _toMap(value);
          final String areaName = _decodeText(_firstText(node, const <String>[
            "areaName",
            "name",
            "partitionName",
            "displayName",
            "label"
          ]));
          out[areaId] = areaName.isEmpty ? "区域$areaId" : areaName;
        } else {
          final String text = _decodeText("${value ?? ""}".trim());
          out[areaId] = text.isEmpty ? "区域$areaId" : text;
        }
      });
    }
    return out;
  }

  String _formatTime(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return "--";
    final int? number = int.tryParse(text);
    if (number == null) return text;
    final bool isSeconds = text.length == 10;
    final DateTime dt =
        DateTime.fromMillisecondsSinceEpoch(isSeconds ? number * 1000 : number);
    return "${dt.year.toString().padLeft(4, "0")}-${dt.month.toString().padLeft(2, "0")}-${dt.day.toString().padLeft(2, "0")} "
        "${dt.hour.toString().padLeft(2, "0")}:${dt.minute.toString().padLeft(2, "0")}";
  }

  Map<String, dynamic> _toMap(dynamic value) {
    if (value is Map) {
      final Map<String, dynamic> out = <String, dynamic>{};
      value.forEach((dynamic key, dynamic v) {
        out["${key ?? ""}"] = v;
      });
      return out;
    }
    return <String, dynamic>{};
  }

  String _firstText(Map<String, dynamic> data, List<String> keys) {
    for (final String key in keys) {
      final String value = "${data[key] ?? ""}".trim();
      if (value.isNotEmpty) return value;
    }
    return "";
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse("${value ?? ""}".replaceAll(",", "").trim()) ?? 0;
  }

  bool _toBool(dynamic value) {
    if (value is bool) return value;
    final String text = "${value ?? ""}".trim().toLowerCase();
    return text == "1" || text == "true" || text == "yes";
  }

  String _decodeText(String value) {
    final String raw = value.trim();
    if (raw.isEmpty) return "";
    try {
      return Uri.decodeComponent(raw);
    } catch (_) {
      return raw;
    }
  }

  void _logRequest({
    required String method,
    required String url,
    Map<String, String>? headers,
    Object? body,
  }) {
    _apiLogService.addRequest(
      method: method,
      url: url,
      headers: headers == null ? null : _maskHeaders(headers),
      body: body,
    );
  }

  void _logResponse({
    required String method,
    required String url,
    required http.Response response,
    String? bodyText,
  }) {
    _apiLogService.addResponse(
      method: method,
      url: url,
      statusCode: response.statusCode,
      headers: response.headers,
      body: bodyText ?? _decodeBody(response),
    );
  }

  Map<String, String> _maskHeaders(Map<String, String> headers) {
    final Map<String, String> copy = Map<String, String>.from(headers);
    if (copy.containsKey("Cookie")) {
      copy["Cookie"] = _maskCookie(copy["Cookie"] ?? "");
    }
    return copy;
  }

  String _maskCookie(String cookie) {
    final List<String> parts =
        cookie.split(";").map((String s) => s.trim()).toList();
    final List<String> masked = <String>[];
    for (final String part in parts) {
      if (part.startsWith("access_token=")) {
        final String token = part.substring("access_token=".length);
        masked.add("access_token=${_maskValue(token)}");
      } else if (part.startsWith("openid=")) {
        final String openid = part.substring("openid=".length);
        masked.add("openid=${_maskValue(openid)}");
      } else {
        masked.add(part);
      }
    }
    return masked.join("; ");
  }

  String _maskValue(String value) {
    if (value.length <= 8) return "****";
    return "${value.substring(0, 4)}...${value.substring(value.length - 4)}";
  }

  _AuthFields _resolveAuthFields({
    required String openid,
    required String accessToken,
    required String appid,
  }) {
    final String rawOpenid = openid.replaceAll(RegExp(r"[\r\n]"), " ").trim();
    final String rawAccessToken =
        accessToken.replaceAll(RegExp(r"[\r\n]"), " ").trim();
    final String merged = "$rawOpenid; $rawAccessToken";

    final String mergedAppId = _extractCookieField(merged, "appid");
    final String resolvedAppId = _normalizeAppId(mergedAppId).isNotEmpty
        ? _normalizeAppId(mergedAppId)
        : _normalizeAppId(appid).isNotEmpty
            ? _normalizeAppId(appid)
            : _defaultAppId;
    final String resolvedOpenId = rawOpenid.contains("=")
        ? _normalizeOpenId(_extractCookieField(merged, "openid"))
        : _normalizeOpenId(rawOpenid).isNotEmpty
            ? _normalizeOpenId(rawOpenid)
            : _normalizeOpenId(_extractCookieField(merged, "openid"));

    final String resolvedAccessToken = _extractAccessToken(rawAccessToken);

    return _AuthFields(
      appid: resolvedAppId,
      openid: resolvedOpenId,
      accessToken: resolvedAccessToken,
    );
  }

  String _extractCookieField(String input, String key) {
    if (input.isEmpty || !input.contains("=")) {
      return "";
    }
    final RegExp reg = RegExp("(?:^|;\\s*)$key=([^;]+)", caseSensitive: false);
    final RegExpMatch? match = reg.firstMatch(input);
    return match?.group(1)?.trim() ?? "";
  }

  String _extractAccessToken(String input) {
    if (input.isEmpty) return "";
    if (!input.contains("=")) return input;
    final String token = _extractCookieField(input, "access_token");
    return token.isNotEmpty ? token : input;
  }

  String _normalizeAppId(String appid) {
    final String text = appid.trim();
    if (!RegExp(r"^\d+$").hasMatch(text)) {
      return "";
    }
    return text;
  }

  String _normalizeOpenId(String openid) {
    return openid.trim();
  }

  String _decodeBody(http.Response response) {
    if (response.bodyBytes.isEmpty) {
      return "";
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  Map<String, dynamic> _decodeJsonMap(String rawBody) {
    final String text = rawBody.trim();
    if (text.isEmpty) {
      return <String, dynamic>{};
    }
    final dynamic decoded = jsonDecode(text);
    if (decoded is Map) {
      return _toMap(decoded);
    }
    return <String, dynamic>{};
  }
}

class _AuthFields {
  const _AuthFields({
    required this.appid,
    required this.openid,
    required this.accessToken,
  });

  final String appid;
  final String openid;
  final String accessToken;
}

class _NumericEntry {
  const _NumericEntry({required this.key, required this.value});

  final String key;
  final int value;
}

class _DiffAgg {
  _DiffAgg({required this.diffName});

  final String diffName;
  int total = 0;
  int win = 0;
}

class _FragmentCountInfo {
  const _FragmentCountInfo({
    required this.current,
    required this.target,
  });

  final int current;
  final int target;
}

class _MapAgg {
  _MapAgg({
    required this.mapName,
    required this.mapId,
    required this.iconUrl,
  });

  String mapName;
  final String mapId;
  String iconUrl;
  int total = 0;
  int win = 0;
  final Map<String, _DiffAgg> difficulty = <String, _DiffAgg>{};
}




