import "dart:async";
import "dart:convert";
import "dart:math";

import "package:flutter/foundation.dart";

import "../models/account_binding.dart";
import "../models/dashboard_models.dart";
import "../models/qiniu_config.dart";
import "../services/account_store.dart";
import "../services/dashboard_cache_store.dart";
import "../services/local_records_store.dart";
import "../services/nzm_api_service.dart";
import "../services/qiniu_cloud_service.dart";
import "../services/qiniu_config_store.dart";
import "../services/storage_permission_service.dart";

enum RootTab { stats, history, local, profile, logs }

enum StatsSubTab { stats, collection }

enum LocalSubTab { stats, battle }

class AppController extends ChangeNotifier {
  AppController({
    NzmApiService? apiService,
    AccountStore? accountStore,
    LocalRecordsStore? localRecordsStore,
    DashboardCacheStore? dashboardCacheStore,
    StoragePermissionService? storagePermissionService,
    QiniuCloudService? qiniuCloudService,
    QiniuConfigStore? qiniuConfigStore,
  })  : _apiService = apiService ?? NzmApiService(),
        _accountStore = accountStore ?? AccountStore(),
        _localRecordsStore = localRecordsStore ?? LocalRecordsStore(),
        _dashboardCacheStore = dashboardCacheStore ?? DashboardCacheStore(),
        _storagePermissionService = storagePermissionService,
        _qiniuCloudService = qiniuCloudService ?? QiniuCloudService(),
        _qiniuConfigStore = qiniuConfigStore ?? QiniuConfigStore() {
    statsData = StatsData.empty();
    historyRecords = const <BattleRecord>[];
    localStatsData = LocalStatsData.empty();
    collectionData = CollectionData.empty();
    qiniuConfig = QiniuConfig.empty();
  }

  final NzmApiService _apiService;
  final AccountStore _accountStore;
  final LocalRecordsStore _localRecordsStore;
  final DashboardCacheStore _dashboardCacheStore;
  StoragePermissionService? _storagePermissionService;
  final QiniuCloudService _qiniuCloudService;
  final QiniuConfigStore _qiniuConfigStore;
  StoragePermissionService get storagePermissionService =>
      _storagePermissionService ??= StoragePermissionService();

  static const String _all = "全部";
  static const String _allModeLabel = "全部模式";
  static const String _allDifficultyLabel = "全部难度";
  static const String _remarkFilterAll = "all";
  static const String _remarkFilterHas = "has";
  static const String _remarkFilterNone = "none";
  static final RegExp _spacesRegExp = RegExp(r"\s+");
  bool _initialized = false;

  RootTab rootTab = RootTab.stats;
  StatsSubTab statsSubTab = StatsSubTab.stats;
  LocalSubTab localSubTab = LocalSubTab.stats;

  bool isLoading = false;
  bool isRefreshingData = false;
  String refreshProgressText = "";
  String statusMessage = "";
  bool lastRefreshUnauthorized = false;

  List<AccountBinding> accounts = <AccountBinding>[];
  String activeUin = "";

  late StatsData statsData;
  late List<BattleRecord> historyRecords;
  late LocalStatsData localStatsData;
  late CollectionData collectionData;
  late QiniuConfig qiniuConfig;
  String localStorePath = "";

  final Map<String, MatchDetailData> _detailCache = <String, MatchDetailData>{};
  final Map<String, String> _detailErrors = <String, String>{};
  final Set<String> _detailLoading = <String>{};

  int historyPage = 1;
  final int historyPageSize = 10;
  int historyTotalPages = 1;
  int historyTotalCount = 0;
  bool isHistoryLoading = false;
  String historyModeFilter = _all;
  String historyDifficultyFilter = _all;
  final Set<String> _historyModeValues = <String>{};
  final Set<String> _historyDifficultyValues = <String>{};
  final Map<String, String> _historyModeLabels = <String, String>{};
  final Map<String, String> _historyDifficultyLabels = <String, String>{};
  final Map<String, String> _historyMapLabels = <String, String>{};

  int localBattlePage = 1;
  final int localBattlePageSize = 10;
  String localModeFilter = _all;
  String localDifficultyFilter = _all;
  String localMapFilter = _all;
  String localRemarkFilter = _remarkFilterAll;
  Map<String, BattleRemark> _recordRemarks = <String, BattleRemark>{};
  Map<String, int> _localModeNthByRecordKey = <String, int>{};

  AccountBinding? get activeAccount {
    for (final AccountBinding account in accounts) {
      if (account.uin == activeUin) {
        return account;
      }
    }
    return null;
  }

  bool get hasBoundAccount => activeAccount != null;

  BattleRemark? remarkForRecord(BattleRecord record) {
    return _recordRemarks[recordIdentityKey(record)];
  }

  int suggestedModeNthForRecord(BattleRecord record) {
    final String key = recordIdentityKey(record);
    if (key.isEmpty) return 1;
    if (!_localModeNthByRecordKey.containsKey(key)) return 1;
    return _predictRemarkNthByTime(record, _recordRemarks);
  }

  String recordIdentityKey(BattleRecord record) {
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

  Future<void> saveRemarkForRecord({
    required BattleRecord record,
    required String text,
  }) async {
    final AccountBinding? account = activeAccount;
    if (account == null) {
      setStatus("请先绑定账号");
      return;
    }
    final String key = recordIdentityKey(record);
    if (key.isEmpty) {
      setStatus("该战绩缺少唯一标识，无法备注");
      return;
    }
    if (!_localModeNthByRecordKey.containsKey(key)) {
      setStatus("只能在本地战绩中备注");
      return;
    }
    final String cleanText = _sanitizeRemarkText(text);
    final int safeNth = suggestedModeNthForRecord(record);
    final Map<String, BattleRemark> previous =
        Map<String, BattleRemark>.from(_recordRemarks);
    final Map<String, BattleRemark> next =
        Map<String, BattleRemark>.from(_recordRemarks);
    if (cleanText.isEmpty) {
      next.remove(key);
    } else {
      next[key] = BattleRemark(
        modeNth: safeNth < 1 ? 1 : safeNth,
        text: cleanText,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
    _reindexRemarkNthByTime(next, modeKey: _modeOccurrenceKey(record));
    final int recovered = _recoverUnexpectedClearedRemarks(
      previous: previous,
      next: next,
      editedKey: key,
    );
    if (recovered > 0) {
      _reindexRemarkNthByTime(next);
    }
    _recordRemarks = next;
    final List<BattleRecord> patchedRecords =
        _applyRemarkMapToRecords(localStatsData.records, _recordRemarks);
    localStatsData = _localRecordsStore.buildLocalStatsFromRecords(patchedRecords);
    await _localRecordsStore.persistRecords(
      uin: account.uin,
      records: patchedRecords,
    );
    _rebuildModeOccurrenceCaches();
    notifyListeners();
    if (recovered > 0) {
      setStatus("检测到 $recovered 条其它备注异常为空，已自动恢复并保存");
      return;
    }
    if (cleanText.isEmpty) {
      setStatus("备注已清除");
    } else {
      setStatus("备注已保存");
    }
  }

  MatchDetailData? detailByRoomId(String roomId) => _detailCache[roomId];

  String? detailErrorByRoomId(String roomId) => _detailErrors[roomId];

  bool isDetailLoading(String roomId) => _detailLoading.contains(roomId);

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final AccountStoreSnapshot snapshot = await _accountStore.load();
    qiniuConfig = await _qiniuConfigStore.load();

    accounts = _dedupeAccounts(snapshot.accounts);
    activeUin = snapshot.activeUin.trim();
    if (activeUin.isEmpty ||
        !accounts.any((AccountBinding e) => e.uin == activeUin)) {
      activeUin = accounts.isNotEmpty ? accounts.first.uin : "";
    }

    await _loadLocalStatsForActive();
    await _loadDashboardCacheForActive();
    await _syncLocalJsonFromCurrentHistory();
    notifyListeners();

    if (activeAccount != null) {
      setStatus("已从本地 JSON 加载缓存数据，点击刷新可同步最新数据");
    } else {
      setStatus("未绑定账号");
    }
  }

  void setRootTab(RootTab tab) {
    rootTab = tab;
    if (tab == RootTab.local) {
      unawaited(_ensureLocalStoragePermission());
    }
    notifyListeners();
  }

  void setStatsSubTab(StatsSubTab tab) {
    statsSubTab = tab;
    notifyListeners();
  }

  void setLocalSubTab(LocalSubTab tab) {
    localSubTab = tab;
    notifyListeners();
  }

  Future<void> bindOrUpdateAccount({
    required String openid,
    required String accessToken,
  }) async {
    final String openidClean = openid.trim();
    final String tokenClean = accessToken.trim();

    if (openidClean.isEmpty || tokenClean.isEmpty) {
      setStatus("openid 和 token 不能为空");
      return;
    }
    if (_spacesRegExp.hasMatch(openidClean) ||
        _spacesRegExp.hasMatch(tokenClean)) {
      setStatus("openid/token 不能包含空白字符");
      return;
    }

    setLoading(true, message: "正在校验账号...");
    try {
      accounts = List<AccountBinding>.from(accounts);
      final RemoteUserInfo? remoteUser = await _apiService.fetchUserInfo(
        openid: openidClean,
        accessToken: tokenClean,
      );
      if (remoteUser == null || remoteUser.uin.trim().isEmpty) {
        setStatus("校验失败，请检查 openid/token 是否正确");
        return;
      }

      final String resolvedUin = remoteUser.uin.trim();
      RemoteUserInfo? detailProfile;
      try {
        detailProfile = await _resolveProfileFromLatestHistoryDetail(
          openid: openidClean,
          accessToken: tokenClean,
          uin: resolvedUin,
        );
      } catch (_) {
        detailProfile = null;
      }
      final String resolvedNickname = _resolveAccountDisplayName(
        (detailProfile?.nickname ?? remoteUser.nickname),
        resolvedUin,
      );
      final AccountBinding account = AccountBinding(
        uin: resolvedUin,
        openid: openidClean,
        accessToken: tokenClean,
        nickname: resolvedNickname,
        avatar: (detailProfile?.avatar.trim().isNotEmpty ?? false)
            ? detailProfile!.avatar.trim()
            : remoteUser.avatar.trim(),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );

      final int openidIdx =
          accounts.indexWhere((AccountBinding e) => e.openid == openidClean);
      final int uinIdx =
          accounts.indexWhere((AccountBinding e) => e.uin == resolvedUin);
      final bool exactSame = accounts.any(
        (AccountBinding e) =>
            e.openid == openidClean &&
            e.uin == resolvedUin &&
            e.accessToken == tokenClean,
      );

      if (exactSame) {
        setStatus("账号已存在，已切换为当前账号");
      } else if (openidIdx >= 0) {
        accounts[openidIdx] = account;
        setStatus("检测到重复 openid，已更新账号");
      } else if (uinIdx >= 0) {
        accounts[uinIdx] = account;
        setStatus("检测到重复 uin，已更新账号");
      } else {
        accounts = <AccountBinding>[account, ...accounts];
        setStatus("账号已添加：${account.displayName}");
      }

      accounts = _dedupeAccounts(accounts);
      activeUin = resolvedUin;
      if (!accounts.any((AccountBinding e) => e.uin == activeUin)) {
        activeUin = accounts.isNotEmpty ? accounts.first.uin : "";
      }

      _clearDetailCache();
      _resetPagingAndFilters();
      Object? postBindError;
      StackTrace? postBindStack;
      try {
        await _persistAccountState();
      } catch (error, stack) {
        postBindError ??= error;
        postBindStack ??= stack;
      }
      try {
        await _loadLocalStatsForActive();
      } catch (error, stack) {
        postBindError ??= error;
        postBindStack ??= stack;
      }
      try {
        await _loadDashboardCacheForActive();
      } catch (error, stack) {
        postBindError ??= error;
        postBindStack ??= stack;
      }
      try {
        await _syncLocalJsonFromCurrentHistory();
      } catch (error, stack) {
        // Keep binding success even when history sync fails.
        postBindError ??= error;
        postBindStack ??= stack;
      }
      try {
        await _tryRefreshActiveAccountProfileFromHistory(account);
      } catch (error, stack) {
        // Keep binding success even when profile refresh fails.
        postBindError ??= error;
        postBindStack ??= stack;
      }
      notifyListeners();
      if (postBindError != null) {
        debugPrint("bind post init warning: $postBindError\n$postBindStack");
        setStatus("账号已绑定，但初始化部分失败：${_cleanErrorText(postBindError)}");
      } else {
        setStatus("账号已更新，已加载本地 JSON 缓存");
      }
    } catch (error, stackTrace) {
      debugPrint("bind failed: $error\n$stackTrace");
      setStatus("绑定失败：${error.runtimeType}: ${_cleanErrorText(error)}");
    } finally {
      setLoading(false);
    }
  }

  Future<void> switchActiveAccount(String uin) async {
    final String next = uin.trim();
    if (next.isEmpty || next == activeUin) return;
    if (!accounts.any((AccountBinding e) => e.uin == next)) {
      setStatus("账号不存在");
      return;
    }

    activeUin = next;
    _clearDetailCache();
    _resetPagingAndFilters();
    await _persistAccountState();
    await _loadLocalStatsForActive();
    await _loadDashboardCacheForActive();
    await _syncLocalJsonFromCurrentHistory();
    final AccountBinding? current = activeAccount;
    if (current != null) {
      await _tryRefreshActiveAccountProfileFromHistory(current);
    }
    notifyListeners();
    setStatus("账号已切换，已加载本地 JSON 缓存");
  }

  Future<void> removeAccount(String uin) async {
    final String targetUin = uin.trim();
    if (targetUin.isNotEmpty) {
      await _localRecordsStore.clearAllRecordsByUin(uin: targetUin);
    }
    accounts = accounts.where((AccountBinding e) => e.uin != uin).toList();
    if (activeUin == uin) {
      activeUin = accounts.isNotEmpty ? accounts.first.uin : "";
    }

    _clearDetailCache();
    _resetPagingAndFilters();
    await _persistAccountState();
    await _loadLocalStatsForActive();
    await _loadDashboardCacheForActive();
    await _syncLocalJsonFromCurrentHistory();
    notifyListeners();

    if (activeAccount != null) {
      setStatus("账号已删除，已加载本地 JSON 缓存");
    } else {
      setStatus("账号已删除");
    }
  }

  Future<void> refreshAllData({bool showLoading = true}) async {
    final AccountBinding? account = activeAccount;
    if (account == null) {
      lastRefreshUnauthorized = false;
      setStatus("请先绑定账号");
      return;
    }

    if (showLoading) {
      setLoading(true, message: "正在刷新数据...");
    }
    isRefreshingData = true;
    _setRefreshProgress("正在刷新数据统计...");
    try {
      final StatsData nextStats = await _apiService.fetchStats(
        openid: account.openid,
        accessToken: account.accessToken,
      );

      _setRefreshProgress("正在刷新历史战绩...");
      final HistoryPageData nextHistory = await _apiService.fetchHistoryPage(
        openid: account.openid,
        accessToken: account.accessToken,
        page: 1,
        limit: historyPageSize,
        modeType: historyModeFilter == _all ? "" : historyModeFilter,
      );
      _consumeHistoryPage(nextHistory, resetOptions: true);
      await _tryRefreshActiveAccountProfileFromHistory(account);

      _setRefreshProgress("正在刷新收藏图鉴...");
      final CollectionData nextCollection = await _apiService.fetchCollection(
        openid: account.openid,
        accessToken: account.accessToken,
      );

      statsData = nextStats;
      collectionData = nextCollection;
      final Map<String, String> modeOptionsForCache =
          Map<String, String>.from(historyModeOptionLabels)..remove(_all);
      final Map<String, String> difficultyOptionsForCache =
          Map<String, String>.from(historyDifficultyOptionLabels)
            ..remove(_all);
      final Map<String, String> mapOptionsForCache =
          Map<String, String>.from(_historyMapLabels);
      await _dashboardCacheStore.saveByUin(
        uin: account.uin,
        statsData: statsData,
        collectionData: collectionData,
        historyPageData: HistoryPageData(
          records: historyRecords,
          page: historyPage,
          limit: historyPageSize,
          totalPages: historyTotalPages,
          totalCount: historyTotalCount,
          modeOptions: modeOptionsForCache,
          difficultyOptions: difficultyOptionsForCache,
          mapOptions: mapOptionsForCache,
        ),
      );
      _setRefreshProgress("正在同步本地 JSON...");
      List<BattleRecord> recordsForLocal =
          await _fetchHistoryForLocalSync(account);
      if (recordsForLocal.isEmpty) {
        recordsForLocal = historyRecords;
      }
      localStatsData = await _localRecordsStore.upsertRecordsByUin(
        uin: account.uin,
        incomingRecords: recordsForLocal,
      );
      localStorePath = await _localRecordsStore.getStorePathByUin(account.uin);
      await _loadRemarksForActive();
      lastRefreshUnauthorized = false;
      _clearDetailCache();
      _resetOutOfRangePages();
      setStatus(
        "数据已更新并自动写入本地 JSON（${recordsForLocal.length} 条）",
      );
      notifyListeners();
    } catch (error) {
      if (_isUnauthorized(error)) {
        lastRefreshUnauthorized = true;
        statsData = StatsData.empty();
        historyRecords = const <BattleRecord>[];
        historyTotalPages = 1;
        historyTotalCount = 0;
        _historyModeValues.clear();
        _historyDifficultyValues.clear();
        _historyModeLabels.clear();
        _historyDifficultyLabels.clear();
        _historyMapLabels.clear();
        collectionData = CollectionData.empty();
        _clearDetailCache();
        _rebuildModeOccurrenceCaches();
        notifyListeners();
      } else {
        lastRefreshUnauthorized = false;
      }
      setStatus(_friendlyRefreshError(error));
    } finally {
      isRefreshingData = false;
      refreshProgressText = "";
      notifyListeners();
      if (showLoading) setLoading(false);
    }
  }

  Future<void> importLocalJson() async {
    final AccountBinding? account = activeAccount;
    if (account == null) {
      setStatus("请先绑定账号");
      return;
    }

    setLoading(true, message: "正在导入 JSON...");
    try {
      final bool granted =
          await storagePermissionService.ensureForLocalRecords();
      if (!granted) {
        setStatus("未授予存储权限，无法导入本地记录");
        return;
      }
      final LocalJsonImportResult? imported =
          await _localRecordsStore.importByFilePicker(
        uin: account.uin,
        currentRecords: localStatsData.records,
      );
      if (imported == null) {
        setStatus("已取消导入");
        return;
      }
      localStatsData = imported.localStatsData;
      localStorePath = await _localRecordsStore.getStorePathByUin(account.uin);
      await _loadRemarksForActive();
      _resetOutOfRangePages();
      setStatus("JSON 导入完成：新增 ${imported.inserted}，更新 ${imported.updated}");
      notifyListeners();
    } on LocalJsonFormatException {
      setStatus("JSON 导入失败：JSON格式错误");
    } on LocalJsonUinMismatchException catch (error) {
      setStatus("JSON 导入失败：$error");
    } on LocalJsonEmptyRecordsException {
      setStatus("JSON 导入失败：records为空");
    } catch (error) {
      setStatus("JSON 导入失败：$error");
    } finally {
      setLoading(false);
    }
  }

  Future<void> exportLocalJson() async {
    final AccountBinding? account = activeAccount;
    if (account == null) {
      setStatus("请先绑定账号");
      return;
    }

    setLoading(true, message: "正在导出 JSON...");
    try {
      final bool granted =
          await storagePermissionService.ensureForLocalRecords();
      if (!granted) {
        setStatus("未授予存储权限，无法导出本地记录");
        return;
      }
      final LocalJsonExportResult? exported =
          await _localRecordsStore.exportByFilePicker(
        uin: account.uin,
        records: localStatsData.records,
      );
      if (exported == null) {
        setStatus("已取消导出");
        return;
      }
      setStatus("JSON 导出完成：${exported.count} 条（uin: ${exported.uin}）");
    } catch (error) {
      setStatus("JSON 导出失败：$error");
    } finally {
      setLoading(false);
    }
  }

  Future<void> clearImportedLocalDataForActive() async {
    final AccountBinding? account = activeAccount;
    if (account == null) {
      setStatus("请先绑定账号");
      return;
    }
    setLoading(true, message: "正在清除导入数据...");
    try {
      localStatsData = await _localRecordsStore.clearImportedRecordsByUin(
        uin: account.uin,
      );
      localStorePath = await _localRecordsStore.getStorePathByUin(account.uin);
      await _loadRemarksForActive();
      _clearDetailCache();
      _resetOutOfRangePages();
      notifyListeners();
      setStatus("已清除所有导入数据");
    } catch (error) {
      setStatus("清除导入数据失败：${_cleanErrorText(error)}");
    } finally {
      setLoading(false);
    }
  }

  Future<void> clearAllLocalDataForActive() async {
    final AccountBinding? account = activeAccount;
    if (account == null) {
      setStatus("请先绑定账号");
      return;
    }
    setLoading(true, message: "正在清除全部本地数据...");
    try {
      localStatsData = await _localRecordsStore.clearAllRecordsByUin(
        uin: account.uin,
      );
      localStorePath = await _localRecordsStore.getStorePathByUin(account.uin);
      _recordRemarks = <String, BattleRemark>{};
      _clearDetailCache();
      _resetOutOfRangePages();
      notifyListeners();
      setStatus("已清除全部本地数据");
    } catch (error) {
      setStatus("清除全部数据失败：${_cleanErrorText(error)}");
    } finally {
      setLoading(false);
    }
  }

  Future<void> saveQiniuConfig(QiniuConfig next) async {
    setLoading(true, message: "正在保存七牛云配置...");
    try {
      qiniuConfig = await _qiniuConfigStore.save(next);
      final String uin = activeAccount?.uin ?? "unknown";
      final QiniuConnectivityResult tested =
          _qiniuCloudService.testConnectivityNoUpload(
        config: qiniuConfig,
        uin: uin,
      );
      setStatus("七牛云配置已保存，连通性校验通过（key=${tested.key}）");
      notifyListeners();
    } catch (error) {
      qiniuConfig = await _qiniuConfigStore.save(next);
      setStatus("配置已保存，但连通性测试失败：$error");
      notifyListeners();
    } finally {
      setLoading(false);
    }
  }

  Future<void> syncLocalStatsToCloud() async {
    final AccountBinding? account = activeAccount;
    if (account == null) {
      setStatus("请先绑定账号");
      return;
    }

    setLoading(true, message: "正在同步到七牛云...");
    try {
      final Map<String, BattleRemark> remarksForCloud = _mergeRemarkMaps(
        _collectRemarkMapFromRecords(localStatsData.records),
        _recordRemarks,
      );
      final List<BattleRecord> recordsForCloud =
          _applyRemarkMapToRecords(localStatsData.records, remarksForCloud);
      final Map<String, dynamic> cloudPayload =
          await _localRecordsStore.buildCloudPayload(
        uin: account.uin,
        records: recordsForCloud,
      );
      final int uploadCount = cloudPayload["records"] is List
          ? (cloudPayload["records"] as List).length
          : recordsForCloud.length;
      final QiniuSyncResult result = await _qiniuCloudService.syncLocalStats(
        config: qiniuConfig,
        uin: account.uin,
        cloudPayload: cloudPayload,
      );
      setStatus("同步七牛完成：${result.key}（上传 $uploadCount 条）");
    } catch (error) {
      setStatus("同步七牛失败：$error");
    } finally {
      setLoading(false);
    }
  }

  Future<void> pullLocalStatsFromCloud() async {
    final AccountBinding? account = activeAccount;
    if (account == null) {
      setStatus("请先绑定账号");
      return;
    }

    setLoading(true, message: "正在从七牛云拉取...");
    try {
      final QiniuPullResult pulled = await _qiniuCloudService.pullLocalStats(
        config: qiniuConfig,
        uin: account.uin,
      );
      final LocalJsonImportResult merged =
          await _localRecordsStore.importFromPayload(
        uin: account.uin,
        currentRecords: localStatsData.records,
        payload: pulled.payload,
        filePath: pulled.url,
      );
      localStatsData = merged.localStatsData;
      localStorePath = await _localRecordsStore.getStorePathByUin(account.uin);
      await _loadRemarksForActive();
      _resetOutOfRangePages();
      setStatus("云端拉取完成：新增 ${merged.inserted}，更新 ${merged.updated}");
      notifyListeners();
    } catch (error) {
      setStatus("云端拉取失败：$error");
    } finally {
      setLoading(false);
    }
  }

  Future<void> loadMatchDetail(String roomId) async {
    final String key = roomId.trim();
    if (key.isEmpty) return;
    if (_detailCache.containsKey(key) || _detailLoading.contains(key)) return;

    final AccountBinding? account = activeAccount;
    if (account == null) {
      _detailErrors[key] = "未绑定账号";
      notifyListeners();
      return;
    }

    _detailLoading.add(key);
    _detailErrors.remove(key);
    notifyListeners();
    try {
      final Map<String, dynamic> payload = await _apiService.fetchRoomDetail(
        openid: account.openid,
        accessToken: account.accessToken,
        roomId: key,
      );
      _detailCache[key] = _parseMatchDetail(key, payload);
    } catch (error) {
      _detailErrors[key] = _friendlyDetailError(error);
    } finally {
      _detailLoading.remove(key);
      notifyListeners();
    }
  }

  List<String> get historyModeOptions {
    final List<String> out = <String>[_all];
    final Set<String> seen = <String>{_all};
    for (final String key in _historyModeLabels.keys) {
      final String id = key.trim();
      if (id.isEmpty || seen.contains(id)) continue;
      seen.add(id);
      out.add(id);
    }
    final List<String> rest = _historyModeValues
        .where((String e) => e.trim().isNotEmpty && !seen.contains(e.trim()))
        .toList()
      ..sort();
    out.addAll(rest);
    return out;
  }

  List<String> get historyDifficultyOptions =>
      _buildOptions(_historyDifficultyValues);

  Map<String, String> get historyModeOptionLabels {
    final Map<String, String> out = <String, String>{_all: _allModeLabel};
    final Map<String, int> labelCounter = <String, int>{};
    _historyModeLabels.forEach((String _, String label) {
      final String text = label.trim();
      if (text.isEmpty) return;
      labelCounter[text] = (labelCounter[text] ?? 0) + 1;
    });
    _historyModeLabels.forEach((String key, String label) {
      final String id = key.trim();
      final String text = label.trim();
      if (id.isEmpty || text.isEmpty) return;
      if ((labelCounter[text] ?? 0) > 1) {
        out[id] = "$text（$id）";
      } else {
        out[id] = text;
      }
    });
    return out;
  }

  Map<String, String> get historyDifficultyOptionLabels {
    final Map<String, String> out = <String, String>{_all: _allDifficultyLabel};
    out.addAll(_historyDifficultyLabels);
    return out;
  }

  List<BattleRecord> get pagedHistoryRecords => historyRecords;

  void setHistoryModeFilter(String value) {
    historyModeFilter = value;
    historyPage = 1;
    unawaited(_loadHistoryPageFromApi(page: 1));
  }

  void setHistoryDifficultyFilter(String value) {
    historyDifficultyFilter = value;
    historyPage = 1;
    unawaited(_loadHistoryPageFromApi(page: 1));
  }

  void previousHistoryPage() {
    if (historyPage <= 1) return;
    unawaited(_loadHistoryPageFromApi(page: historyPage - 1));
  }

  void nextHistoryPage() {
    if (historyPage >= historyTotalPages) return;
    unawaited(_loadHistoryPageFromApi(page: historyPage + 1));
  }

  List<String> get localModeOptions {
    final List<String> keys = _historyModeValues
        .map((String e) => e.trim())
        .where((String e) => e.isNotEmpty)
        .toSet()
        .toList()
      ..sort((String a, String b) {
        final String la = localModeOptionLabels[a] ?? a;
        final String lb = localModeOptionLabels[b] ?? b;
        return la.compareTo(lb);
      });
    return <String>[_all, ...keys];
  }

  Map<String, String> get localModeOptionLabels {
    final Map<String, String> out = <String, String>{_all: _allModeLabel};
    final Map<String, int> labelCounter = <String, int>{};
    _historyModeLabels.forEach((String _, String label) {
      final String text = label.trim();
      if (text.isEmpty) return;
      labelCounter[text] = (labelCounter[text] ?? 0) + 1;
    });
    _historyModeLabels.forEach((String key, String label) {
      final String id = key.trim();
      final String text = label.trim();
      if (id.isEmpty || text.isEmpty) return;
      if ((labelCounter[text] ?? 0) > 1) {
        out[id] = "$text（$id）";
      } else {
        out[id] = text;
      }
    });
    return out;
  }

  List<String> get localDifficultyOptions {
    return _buildOptions(_historyDifficultyValues);
  }

  Map<String, String> get localDifficultyOptionLabels {
    final Map<String, String> out = <String, String>{_all: _allDifficultyLabel};
    out.addAll(_historyDifficultyLabels);
    return out;
  }

  List<String> get localMapOptions {
    final List<String> keys = _historyMapLabels.keys
        .map((String e) => e.trim())
        .where((String e) => e.isNotEmpty)
        .toSet()
        .toList()
      ..sort((String a, String b) {
        final String la = localMapOptionLabels[a] ?? a;
        final String lb = localMapOptionLabels[b] ?? b;
        return la.compareTo(lb);
      });
    return <String>[_all, ...keys];
  }

  Map<String, String> get localMapOptionLabels {
    final Map<String, String> out = <String, String>{_all: "全部地图"};
    _historyMapLabels.forEach((String key, String label) {
      final String k = key.trim();
      final String text = label.trim();
      if (k.isEmpty) return;
      out[k] = text.isEmpty ? k : text;
    });
    return out;
  }

  List<String> get localRemarkOptions => const <String>[
        _remarkFilterAll,
        _remarkFilterHas,
        _remarkFilterNone,
      ];

  Map<String, String> get localRemarkOptionLabels => const <String, String>{
        _remarkFilterAll: "全部备注",
        _remarkFilterHas: "有备注",
        _remarkFilterNone: "无备注",
      };

  List<BattleRecord> get filteredLocalBattleRecords {
    final String modeFilter =
        localModeOptions.contains(localModeFilter) ? localModeFilter : _all;
    final String difficultyFilter = localDifficultyOptions
            .contains(localDifficultyFilter)
        ? localDifficultyFilter
        : _all;
    final String mapFilter =
        localMapOptions.contains(localMapFilter) ? localMapFilter : _all;
    final String remarkFilter = localRemarkOptions.contains(localRemarkFilter)
        ? localRemarkFilter
        : _remarkFilterAll;
    return localStatsData.records.where((BattleRecord record) {
      final bool modeOk =
          modeFilter == _all || _recordPassesLocalModeFilter(record, modeFilter);
      final bool diffOk = difficultyFilter == _all ||
          _recordPassesLocalDifficultyFilter(record, difficultyFilter);
      final String mapKey = _buildLocalMapFilterKey(
        record.mapName,
        record.modeName,
      );
      final String mapIdKey = record.mapId > 0 ? "${record.mapId}" : "";
      final bool mapOk = mapFilter == _all ||
          mapKey == mapFilter ||
          record.mapName == mapFilter ||
          (mapIdKey.isNotEmpty && mapIdKey == mapFilter);
      final bool hasRemark = _hasRemarkForRecord(record);
      final bool remarkOk = remarkFilter == _remarkFilterAll ||
          (remarkFilter == _remarkFilterHas ? hasRemark : !hasRemark);
      return modeOk && diffOk && mapOk && remarkOk;
    }).toList();
  }

  bool _hasRemarkForRecord(BattleRecord record) {
    final BattleRemark? remark = _recordRemarks[recordIdentityKey(record)];
    if (remark != null && remark.text.trim().isNotEmpty) return true;
    return record.remarkText.trim().isNotEmpty;
  }

  bool _recordPassesLocalModeFilter(BattleRecord record, String modeFilter) {
    final String recordModeId = record.modeType > 0 ? "${record.modeType}" : "";
    if (recordModeId.isNotEmpty && recordModeId == modeFilter) {
      return true;
    }
    final String label = _historyModeLabels[modeFilter]?.trim() ?? "";
    if (label.isNotEmpty && record.modeName.trim() == label) {
      return true;
    }
    return record.modeName.trim() == modeFilter;
  }

  bool _recordPassesLocalDifficultyFilter(
      BattleRecord record, String difficultyFilter) {
    if (record.difficultyName.trim() == difficultyFilter) {
      return true;
    }
    final String label = _historyDifficultyLabels[difficultyFilter]?.trim() ?? "";
    if (label.isNotEmpty && record.difficultyName.trim() == label) {
      return true;
    }
    return false;
  }

  int get localBattleTotalPages {
    final int total = filteredLocalBattleRecords.length;
    if (total <= 0) return 0;
    return (total / localBattlePageSize).ceil();
  }

  int get localBattleFilteredCount => filteredLocalBattleRecords.length;

  int get localRemarkCount {
    int total = 0;
    for (final BattleRecord record in localStatsData.records) {
      final BattleRemark? remark = _recordRemarks[recordIdentityKey(record)];
      if ((remark != null && remark.text.trim().isNotEmpty) ||
          record.remarkText.trim().isNotEmpty) {
        total += 1;
      }
    }
    return total;
  }

  List<BattleRecord> get pagedLocalBattleRecords {
    final List<BattleRecord> list = filteredLocalBattleRecords;
    if (list.isEmpty || localBattleTotalPages == 0) return const <BattleRecord>[];
    final int safePage = min(max(1, localBattlePage), localBattleTotalPages);
    final int start = (safePage - 1) * localBattlePageSize;
    if (start >= list.length) return const <BattleRecord>[];
    final int end = min(start + localBattlePageSize, list.length);
    return list.sublist(start, end);
  }

  void setLocalModeFilter(String value) {
    localModeFilter = value;
    localBattlePage = 1;
    notifyListeners();
  }

  void setLocalDifficultyFilter(String value) {
    localDifficultyFilter = value;
    localBattlePage = 1;
    notifyListeners();
  }

  void setLocalMapFilter(String value) {
    localMapFilter = value;
    localBattlePage = 1;
    notifyListeners();
  }

  void setLocalRemarkFilter(String value) {
    localRemarkFilter = value;
    localBattlePage = 1;
    notifyListeners();
  }

  void previousLocalBattlePage() {
    if (localBattlePage <= 1) return;
    localBattlePage -= 1;
    notifyListeners();
  }

  void nextLocalBattlePage() {
    if (localBattleTotalPages <= 0 || localBattlePage >= localBattleTotalPages) {
      return;
    }
    localBattlePage += 1;
    notifyListeners();
  }

  void setLoading(bool value, {String message = ""}) {
    isLoading = value;
    if (message.trim().isNotEmpty) statusMessage = message.trim();
    notifyListeners();
  }

  void setStatus(String message) {
    statusMessage = message.trim();
    notifyListeners();
  }

  bool _isUnauthorized(Object error) {
    if (error is ApiUnauthorizedException) return true;
    final String text = error.toString().toLowerCase();
    return text.contains("401") || text.contains("unauthorized");
  }

  String _cleanErrorText(Object error) {
    final String text = error.toString().trim();
    if (text.startsWith("Exception: ")) {
      return text.substring("Exception: ".length).trim();
    }
    return text;
  }

  String _friendlyRefreshError(Object error) {
    if (_isUnauthorized(error)) {
      return "刷新失败：账号授权已失效（401），请在账号页更新 token 后重试";
    }
    return "刷新失败：${_cleanErrorText(error)}";
  }

  String _friendlyDetailError(Object error) {
    if (_isUnauthorized(error)) {
      return "战绩详情加载失败：账号授权已失效（401）";
    }
    return _cleanErrorText(error);
  }

  List<AccountBinding> _dedupeAccounts(List<AccountBinding> source) {
    final List<AccountBinding> sorted = List<AccountBinding>.from(source)
      ..sort((AccountBinding a, AccountBinding b) =>
          b.updatedAt.compareTo(a.updatedAt));
    final Set<String> seenUin = <String>{};
    final Set<String> seenOpenid = <String>{};
    final List<AccountBinding> out = <AccountBinding>[];
    for (final AccountBinding account in sorted) {
      final String uin = account.uin.trim();
      final String openid = account.openid.trim();
      if (uin.isEmpty || openid.isEmpty) continue;
      if (seenUin.contains(uin) || seenOpenid.contains(openid)) continue;
      seenUin.add(uin);
      seenOpenid.add(openid);
      out.add(account.copyWith(nickname: _resolveAccountDisplayName(account.nickname, uin)));
    }
    return out;
  }

  String _resolveAccountDisplayName(
    String nickname,
    String uin, {
    bool allowUinFallback = true,
  }) {
    final String cleanUin = uin.trim();
    String value = nickname.trim();
    if (value.isNotEmpty) {
      for (int i = 0; i < 2; i++) {
        try {
          final String decoded = Uri.decodeComponent(value);
          if (decoded == value) break;
          value = decoded.trim();
        } catch (_) {
          break;
        }
      }
    }
    if (value.isEmpty) {
      return allowUinFallback ? cleanUin : "";
    }
    return value;
  }

  Future<void> _tryRefreshActiveAccountProfileFromHistory(
      AccountBinding account) async {
    try {
      final RemoteUserInfo? profile = await _resolveProfileFromLatestHistoryDetail(
        openid: account.openid,
        accessToken: account.accessToken,
        uin: account.uin,
      );
      if (profile == null) return;
      String nextNickname = _resolveAccountDisplayName(
        profile.nickname,
        account.uin,
        allowUinFallback: false,
      );
      if (nextNickname.trim().isEmpty) {
        nextNickname = "未知玩家";
      }
      final int idx =
          accounts.indexWhere((AccountBinding item) => item.uin == account.uin);
      if (idx < 0) return;
      final AccountBinding current = accounts[idx];
      final String nextAvatar = profile.avatar.trim().isNotEmpty
          ? profile.avatar.trim()
          : current.avatar;
      final bool changedNickname = current.nickname.trim() != nextNickname.trim();
      final bool changedAvatar = current.avatar.trim() != nextAvatar.trim();
      if (!changedNickname && !changedAvatar) return;
      accounts[idx] = current.copyWith(
        nickname: nextNickname.trim(),
        avatar: nextAvatar.trim(),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await _persistAccountState();
    } catch (_) {
      // Ignore profile refresh failures, avoid affecting refresh flow.
    }
  }

  Future<void> _persistAccountState() async {
    await _accountStore.save(accounts: accounts, activeUin: activeUin);
  }

  Future<void> _loadLocalStatsForActive() async {
    final String uin = activeAccount?.uin ?? "";
    if (uin.isEmpty) {
      localStatsData = LocalStatsData.empty();
      localStorePath = "";
      _recordRemarks = <String, BattleRemark>{};
      _rebuildModeOccurrenceCaches();
      return;
    }
    localStatsData = await _localRecordsStore.loadStatsByUin(uin);
    localStorePath = await _localRecordsStore.getStorePathByUin(uin);
    await _loadRemarksForActive();
    _resetOutOfRangePages();
  }

  Future<void> _loadDashboardCacheForActive() async {
    final String uin = activeAccount?.uin ?? "";
    if (uin.isEmpty) {
      statsData = StatsData.empty();
      historyRecords = const <BattleRecord>[];
      historyTotalPages = 1;
      historyTotalCount = 0;
      collectionData = CollectionData.empty();
      return;
    }
    final DashboardCacheSnapshot snapshot =
        await _dashboardCacheStore.loadByUin(uin);
    if (snapshot.isEmpty) {
      statsData = StatsData.empty();
      historyRecords = const <BattleRecord>[];
      historyTotalPages = 1;
      historyTotalCount = 0;
      collectionData = CollectionData.empty();
      return;
    }
    statsData = snapshot.statsData;
    collectionData = snapshot.collectionData;
    _consumeHistoryPage(snapshot.historyPageData, resetOptions: true);
    _rebuildModeOccurrenceCaches();
    _resetOutOfRangePages();
  }

  Future<void> _loadHistoryPageFromApi({required int page}) async {
    final AccountBinding? account = activeAccount;
    if (account == null) {
      historyRecords = const <BattleRecord>[];
      historyPage = 1;
      historyTotalPages = 1;
      historyTotalCount = 0;
      notifyListeners();
      return;
    }
    final int targetPage = page < 1 ? 1 : page;
    isHistoryLoading = true;
    notifyListeners();
    try {
      final HistoryPageData result = await _apiService.fetchHistoryPage(
        openid: account.openid,
        accessToken: account.accessToken,
        page: targetPage,
        limit: historyPageSize,
        modeType: historyModeFilter == _all ? "" : historyModeFilter,
      );
      _consumeHistoryPage(result, resetOptions: false);
    } catch (error) {
      setStatus("历史战绩加载失败：${_cleanErrorText(error)}");
    } finally {
      isHistoryLoading = false;
      notifyListeners();
    }
  }

  void _consumeHistoryPage(HistoryPageData pageData,
      {required bool resetOptions}) {
    if (resetOptions) {
      _historyModeValues.clear();
      _historyDifficultyValues.clear();
      _historyModeLabels.clear();
      _historyDifficultyLabels.clear();
      _historyMapLabels.clear();
    }
    pageData.modeOptions.forEach((String id, String label) {
      final String key = id.trim();
      final String text = label.trim();
      if (key.isEmpty || text.isEmpty) return;
      _historyModeValues.add(key);
      _historyModeLabels[key] = text;
    });
    pageData.difficultyOptions.forEach((String value, String label) {
      final String key = value.trim();
      final String text = label.trim();
      if (key.isEmpty || text.isEmpty) return;
      _historyDifficultyValues.add(key);
      _historyDifficultyLabels[key] = text;
    });
    pageData.mapOptions.forEach((String value, String label) {
      final String key = value.trim();
      final String text = label.trim();
      if (key.isEmpty || text.isEmpty) return;
      if (key.contains("__mode__")) {
        _historyMapLabels[key] = text;
      }
    });
    for (final BattleRecord record in pageData.records) {
      if (record.modeType > 0) {
        final String key = "${record.modeType}";
        _historyModeValues.add(key);
        _historyModeLabels.putIfAbsent(
            key,
            () => record.modeName.trim().isEmpty
                ? "模式$key"
                : record.modeName.trim());
      }
      final String diffName = record.difficultyName.trim();
      if (diffName.isNotEmpty) {
        _historyDifficultyValues.add(diffName);
        _historyDifficultyLabels.putIfAbsent(diffName, () => diffName);
      }
      final String mapName = record.mapName.trim();
      if (mapName.isNotEmpty) {
        final String mapKey = _buildLocalMapFilterKey(mapName, record.modeName);
        _historyMapLabels.putIfAbsent(
          mapKey,
          () => _formatLocalMapFilterLabel(mapName, record.modeName),
        );
      }
    }
    historyPage = pageData.page < 1 ? 1 : pageData.page;
    historyTotalPages = pageData.totalPages < 1 ? 1 : pageData.totalPages;
    historyTotalCount = pageData.totalCount < 0 ? 0 : pageData.totalCount;
    historyRecords = pageData.records
        .where((BattleRecord record) => _recordPassesHistoryFilter(record))
        .toList();
    _rebuildModeOccurrenceCaches();
  }

  bool _recordPassesHistoryFilter(BattleRecord record) {
    final bool diffOk = historyDifficultyFilter == _all ||
        record.difficultyName == historyDifficultyFilter;
    return diffOk;
  }

  void _clearDetailCache() {
    _detailCache.clear();
    _detailErrors.clear();
    _detailLoading.clear();
  }

  void _resetPagingAndFilters() {
    historyPage = 1;
    historyTotalPages = 1;
    historyTotalCount = 0;
    localBattlePage = 1;
    historyModeFilter = _all;
    historyDifficultyFilter = _all;
    _historyModeValues.clear();
    _historyDifficultyValues.clear();
    _historyModeLabels.clear();
    _historyDifficultyLabels.clear();
    _historyMapLabels.clear();
    localModeFilter = _all;
    localDifficultyFilter = _all;
    localMapFilter = _all;
  }

  void _setRefreshProgress(String text) {
    refreshProgressText = text.trim();
    statusMessage = refreshProgressText;
    notifyListeners();
  }

  Future<void> _ensureLocalStoragePermission() async {
    final bool granted = await storagePermissionService.ensureForLocalRecords();
    if (!granted) {
      statusMessage = "未授予存储权限，部分本地记录功能不可用";
      notifyListeners();
    }
  }

  Future<void> _syncLocalJsonFromCurrentHistory() async {
    final AccountBinding? account = activeAccount;
    if (account == null || historyRecords.isEmpty) return;
    localStatsData = await _localRecordsStore.upsertRecordsByUin(
      uin: account.uin,
      incomingRecords: historyRecords,
    );
    localStorePath = await _localRecordsStore.getStorePathByUin(account.uin);
    await _loadRemarksForActive();
    _resetOutOfRangePages();
  }

  Future<RemoteUserInfo?> _resolveProfileFromLatestHistoryDetail({
    required String openid,
    required String accessToken,
    required String uin,
  }) async {
    try {
      final HistoryPageData page = await _apiService.fetchHistoryPage(
        openid: openid,
        accessToken: accessToken,
        page: 1,
        limit: 1,
      );
      if (page.records.isEmpty) return null;
      final String roomId = page.records.first.roomId.trim();
      if (roomId.isEmpty) return null;
      final Map<String, dynamic> raw = await _apiService.fetchRoomDetail(
        openid: openid,
        accessToken: accessToken,
        roomId: roomId,
      );
      final Map<String, dynamic> payload =
          _asMap(raw["data"]).isNotEmpty ? _asMap(raw["data"]) : _asMap(raw);
      final Map<String, dynamic> loginUserDetail =
          _asMap(payload["loginUserDetail"]);
      final String loginNickname = _decodeText(_firstTextFromMap(
        loginUserDetail,
        const <String>["nickname", "name", "nickName", "sNickName"],
        "",
      ));
      final String loginAvatar = _firstTextFromMap(
        loginUserDetail,
        const <String>["avatar", "avatarUrl", "headUrl"],
        "",
      );
      if (loginNickname.trim().isNotEmpty || loginAvatar.trim().isNotEmpty) {
        return RemoteUserInfo(
          uin: uin,
          nickname: loginNickname,
          avatar: loginAvatar,
        );
      }
      final List<Map<String, dynamic>> players = _extractPlayerNodes(payload);
      if (players.isEmpty) return null;
      Map<String, dynamic>? target;
      int toInt(dynamic value) {
        if (value is int) return value;
        if (value is num) return value.toInt();
        return int.tryParse("${value ?? ""}".trim()) ?? 0;
      }

      for (final Map<String, dynamic> node in players) {
        final int selfFlag = toInt(
            node["isSelf"] ?? node["self"] ?? node["isMe"] ?? node["iSelf"]);
        if (selfFlag == 1) {
          target = node;
          break;
        }
      }
      target ??= players.first;
      final String nickname = _decodeText(_firstTextFromMap(
        target,
        const <String>["nickname", "name", "nickName", "sNickName"],
        "",
      ));
      final String avatar = _firstTextFromMap(
        target,
        const <String>["avatar", "avatarUrl", "headUrl"],
        "",
      );
      if (nickname.trim().isEmpty && avatar.trim().isEmpty) return null;
      return RemoteUserInfo(
        uin: uin,
        nickname: nickname,
        avatar: avatar,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<BattleRecord>> _fetchHistoryForLocalSync(
    AccountBinding account,
  ) async {
    const int limit = 10;
    const int maxPages = 100;
    int page = 1;
    final Map<String, BattleRecord> byRoom = <String, BattleRecord>{};

    while (page <= maxPages) {
      final HistoryPageData current = await _apiService.fetchHistoryPage(
        openid: account.openid,
        accessToken: account.accessToken,
        page: page,
        limit: limit,
        modeType: "",
      );
      int added = 0;
      for (final BattleRecord record in current.records) {
        final String key = record.roomId.trim();
        if (key.isEmpty) continue;
        if (!byRoom.containsKey(key)) {
          added += 1;
        }
        byRoom[key] = record;
      }
      final bool reachedByEmptyPage = current.records.isEmpty;
      final bool reachedByNoNewData = added == 0;
      final bool reachedByTotalPages =
          current.totalPages > 1 && page >= current.totalPages;
      if (reachedByEmptyPage || reachedByNoNewData || reachedByTotalPages) {
        break;
      }
      page += 1;
    }

    final List<BattleRecord> out = byRoom.values.toList()
      ..sort((BattleRecord a, BattleRecord b) => _recordTimeMs(b).compareTo(
            _recordTimeMs(a),
          ));
    return out;
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

  void _resetOutOfRangePages() {
    historyPage = min(max(1, historyPage), max(1, historyTotalPages));
    if (localBattleTotalPages <= 0) {
      localBattlePage = 0;
    } else {
      localBattlePage = min(max(1, localBattlePage), localBattleTotalPages);
    }
  }

  List<String> _buildOptions(Iterable<String> source) {
    final Set<String> values = <String>{};
    for (final String item in source) {
      final String trimmed = item.trim();
      if (trimmed.isNotEmpty) values.add(trimmed);
    }
    final List<String> sorted = values.toList()..sort();
    return <String>[_all, ...sorted];
  }

  Future<void> _loadRemarksForActive() async {
    final String uin = activeAccount?.uin ?? "";
    if (uin.isEmpty) {
      _recordRemarks = <String, BattleRemark>{};
      _rebuildModeOccurrenceCaches();
      return;
    }
    final Map<String, BattleRemark> loadedFromStore =
        Map<String, BattleRemark>.from(
      await _localRecordsStore.loadRemarksByUin(uin),
    );
    final Map<String, BattleRemark> loaded = _mergeRemarkMaps(
      _collectRemarkMapFromRecords(localStatsData.records),
      loadedFromStore,
    );
    final int beforePrune = loaded.length;
    final Set<String> validKeys = localStatsData.records
        .map(recordIdentityKey)
        .where((String e) => e.isNotEmpty)
        .toSet();
    loaded.removeWhere((String key, BattleRemark _) {
      return !validKeys.contains(key);
    });
    final int pruned = beforePrune - loaded.length;
    final int reindexed = _reindexRemarkNthByTime(loaded);
    final List<BattleRecord> patchedRecords =
        _applyRemarkMapToRecords(localStatsData.records, loaded);
    localStatsData = _localRecordsStore.buildLocalStatsFromRecords(patchedRecords);
    if (pruned > 0 || reindexed > 0 || !_remarkMapsEqual(loaded, loadedFromStore)) {
      await _localRecordsStore.persistRecords(
        uin: uin,
        records: patchedRecords,
      );
    }
    _recordRemarks = loaded;
    _rebuildModeOccurrenceCaches();
  }

  String _sanitizeRemarkText(String raw) {
    final String cleaned = raw
        .replaceAll(RegExp(r"[\r\n\t]+"), " ")
        .replaceAll(RegExp(r"[<>]"), "")
        .replaceAll(RegExp(r"\s+"), " ")
        .trim();
    return cleaned;
  }

  int _recoverUnexpectedClearedRemarks({
    required Map<String, BattleRemark> previous,
    required Map<String, BattleRemark> next,
    required String editedKey,
  }) {
    int recovered = 0;
    previous.forEach((String key, BattleRemark oldRemark) {
      if (key == editedKey) return;
      final String before = oldRemark.text.trim();
      if (before.isEmpty) return;
      final BattleRemark? current = next[key];
      final String after = current?.text.trim() ?? "";
      if (after.isEmpty) {
        next[key] = oldRemark;
        recovered += 1;
      }
    });
    return recovered;
  }

  int _reindexRemarkNthByTime(Map<String, BattleRemark> remarks,
      {String? modeKey}) {
    final Map<String, BattleRecord> localByKey = <String, BattleRecord>{};
    for (final BattleRecord record in localStatsData.records) {
      final String key = recordIdentityKey(record);
      if (key.isEmpty) continue;
      localByKey[key] = record;
    }
    final Map<String, List<String>> keysByMode = <String, List<String>>{};
    remarks.forEach((String key, BattleRemark remark) {
      if (remark.text.trim().isEmpty) return;
      final BattleRecord? record = localByKey[key];
      if (record == null) return;
      final String mk = _modeOccurrenceKey(record);
      if (modeKey != null && mk != modeKey) return;
      keysByMode.putIfAbsent(mk, () => <String>[]).add(key);
    });
    int changed = 0;
    keysByMode.forEach((String _, List<String> keys) {
      keys.sort((String a, String b) {
        final BattleRecord? ra = localByKey[a];
        final BattleRecord? rb = localByKey[b];
        final int ta = ra == null ? 0 : _recordTimeMs(ra);
        final int tb = rb == null ? 0 : _recordTimeMs(rb);
        final int byTime = ta.compareTo(tb);
        if (byTime != 0) return byTime;
        return a.compareTo(b);
      });
      for (int i = 0; i < keys.length; i += 1) {
        final String key = keys[i];
        final BattleRemark? old = remarks[key];
        if (old == null) continue;
        final int nth = i + 1;
        if (old.modeNth != nth) {
          remarks[key] = old.copyWith(modeNth: nth);
          changed += 1;
        }
      }
    });
    return changed;
  }

  Map<String, BattleRemark> _collectRemarkMapFromRecords(
      List<BattleRecord> records) {
    final Map<String, BattleRemark> out = <String, BattleRemark>{};
    for (final BattleRecord record in records) {
      final String key = recordIdentityKey(record);
      if (key.isEmpty) continue;
      final String text = _sanitizeRemarkText(record.remarkText);
      if (text.isEmpty) continue;
      final BattleRemark next = BattleRemark(
        modeNth: record.remarkModeNth < 0 ? 0 : record.remarkModeNth,
        text: text,
        updatedAt: record.remarkUpdatedAt < 0 ? 0 : record.remarkUpdatedAt,
      );
      out[key] = _pickPreferredRemark(out[key], next);
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

  bool _remarkMapsEqual(
    Map<String, BattleRemark> a,
    Map<String, BattleRemark> b,
  ) {
    if (a.length != b.length) return false;
    for (final String key in a.keys) {
      final BattleRemark? left = a[key];
      final BattleRemark? right = b[key];
      if (left == null || right == null) return false;
      if (left.text.trim() != right.text.trim()) return false;
      if (left.modeNth != right.modeNth) return false;
      if (left.updatedAt != right.updatedAt) return false;
    }
    return true;
  }

  int _predictRemarkNthByTime(
      BattleRecord record, Map<String, BattleRemark> remarks) {
    final String currentKey = recordIdentityKey(record);
    if (currentKey.isEmpty) return 1;
    final String modeKey = _modeOccurrenceKey(record);
    final List<String> keys = <String>[];
    for (final BattleRecord localRecord in localStatsData.records) {
      final String key = recordIdentityKey(localRecord);
      if (key.isEmpty) continue;
      if (_modeOccurrenceKey(localRecord) != modeKey) continue;
      final BattleRemark? remark = remarks[key];
      if (remark != null && remark.text.trim().isNotEmpty) {
        keys.add(key);
      }
    }
    if (!keys.contains(currentKey)) {
      keys.add(currentKey);
    }
    if (keys.isEmpty) return 1;
    final Map<String, BattleRecord> byKey = <String, BattleRecord>{};
    for (final BattleRecord localRecord in localStatsData.records) {
      final String key = recordIdentityKey(localRecord);
      if (key.isEmpty) continue;
      byKey[key] = localRecord;
    }
    keys.sort((String a, String b) {
      final BattleRecord? ra = byKey[a];
      final BattleRecord? rb = byKey[b];
      final int ta = ra == null ? 0 : _recordTimeMs(ra);
      final int tb = rb == null ? 0 : _recordTimeMs(rb);
      final int byTime = ta.compareTo(tb);
      if (byTime != 0) return byTime;
      return a.compareTo(b);
    });
    final int index = keys.indexOf(currentKey);
    return index < 0 ? 1 : index + 1;
  }

  List<BattleRecord> _applyRemarkMapToRecords(
    List<BattleRecord> records,
    Map<String, BattleRemark> remarks,
  ) {
    return records.map((BattleRecord record) {
      final String key = recordIdentityKey(record);
      final BattleRemark? remark = key.isEmpty ? null : remarks[key];
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
    }).toList();
  }

  void _rebuildModeOccurrenceCaches() {
    _localModeNthByRecordKey = _buildModeOccurrenceMap(localStatsData.records);
  }

  Map<String, int> _buildModeOccurrenceMap(List<BattleRecord> records) {
    final Map<String, int> out = <String, int>{};
    final Map<String, int> counters = <String, int>{};
    for (final BattleRecord record in records) {
      final String idKey = recordIdentityKey(record);
      if (idKey.isEmpty) continue;
      final String modeKey = _modeOccurrenceKey(record);
      final int nth = (counters[modeKey] ?? 0) + 1;
      counters[modeKey] = nth;
      out[idKey] = nth;
    }
    return out;
  }

  String _modeOccurrenceKey(BattleRecord record) {
    if (record.modeType > 0) {
      return "mode:${record.modeType}";
    }
    return record.modeName.trim().toLowerCase();
  }

  String _normalizeRoomId(String value) {
    final String raw = value.trim();
    if (raw.isEmpty) return "";
    return raw.replaceAll(RegExp(r"[^0-9A-Za-z_-]"), "").toLowerCase();
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
    if (normalizedModeName.isEmpty) {
      return normalizedMapName;
    }
    return "$normalizedMapName（$normalizedModeName）";
  }

  MatchDetailData _parseMatchDetail(String roomId, Map<String, dynamic> raw) {
    Map<String, dynamic> payload = raw;
    final Map<String, dynamic> dataPayload = _asMap(raw["data"]);
    if (dataPayload.isNotEmpty) {
      payload = dataPayload;
    }
    final Map<String, String> partitionAreaMap = <String, String>{};
    final dynamic partitionMapRaw =
        payload["partitionAreaMap"] ?? raw["partitionAreaMap"];
    if (partitionMapRaw is Map) {
      final Map<String, dynamic> pm = _asMap(partitionMapRaw);
      pm.forEach((String key, dynamic value) {
        final String id = key.trim();
        if (id.isEmpty) return;
        final String name = _decodeText("${value ?? ""}".trim());
        if (name.isNotEmpty) {
          partitionAreaMap[id] = name;
        }
      });
    }
    final List<Map<String, dynamic>> rawPlayers = _extractPlayerNodes(payload);
    final List<MatchPlayerDetail> players = rawPlayers
        .map((Map<String, dynamic> node) =>
            _parsePlayerDetail(node, partitionAreaMap))
        .toList();
    return MatchDetailData(
      roomId: roomId,
      players: players,
      rawPayload: payload,
    );
  }

  MatchPlayerDetail _parsePlayerDetail(
      Map<String, dynamic> item, Map<String, String> partitionAreaMap) {
    int toInt(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse("${value ?? ""}".replaceAll(",", "").trim()) ?? 0;
    }

    final Map<String, dynamic> baseDetail = _asMap(item["baseDetail"]);
    final Map<String, dynamic> hunting = _asMap(item["huntingDetails"]);
    final List<MatchPartitionDetail> partitionDetails =
        _parsePartitionDetails(hunting["partitionDetails"], partitionAreaMap);

    final List<dynamic> equipmentRaw = _asList(item["equipmentScheme"]);
    final List<MatchEquipment> equipments = equipmentRaw
        .map((dynamic e) => _asMap(e))
        .where((Map<String, dynamic> e) => e.isNotEmpty)
        .map((Map<String, dynamic> equipment) {
      final List<dynamic> commonRaw = _asList(equipment["commonItems"]);
      return MatchEquipment(
        name: _decodeText(_firstTextFromMap(
            equipment, const <String>["weaponName", "name"], "未知装备")),
        iconUrl: _resolveImageUrl(_firstTextFromMap(
            equipment, const <String>["pic", "icon", "weaponIcon"], "")),
        commonItems: commonRaw
            .map((dynamic c) => _asMap(c))
            .where((Map<String, dynamic> c) => c.isNotEmpty)
            .map((Map<String, dynamic> c) {
          return MatchCommonItem(
            name: _decodeText(_firstTextFromMap(
                c, const <String>["itemName", "name"], "未知道具")),
            iconUrl: _resolveImageUrl(_firstTextFromMap(
                c, const <String>["pic", "icon", "itemIcon"], "")),
          );
        }).toList(),
      );
    }).toList();

    return MatchPlayerDetail(
      nickname: _decodeText(
          _firstTextFromMap(item, const <String>["nickname", "name"], "未知玩家")),
      avatarUrl: _resolveImageUrl(_firstTextFromMap(
          item, const <String>["avatar", "avatarUrl", "headUrl"], "")),
      isSelf: toInt(item["isSelf"] ?? item["self"] ?? item["isMe"] ?? item["iSelf"]) ==
          1,
      totalCoin: toInt(
          hunting["totalCoin"] ?? hunting["coin"] ?? hunting["totalCoins"]),
      bossDamage: toInt(hunting["damageTotalOnBoss"] ??
          hunting["bossDamage"] ??
          hunting["damageBoss"]),
      mobsDamage: toInt(hunting["damageTotalOnMobs"] ??
          hunting["mobsDamage"] ??
          hunting["damageMobs"]),
      score: toInt(item["iScore"] ??
          baseDetail["iScore"] ??
          item["score"] ??
          baseDetail["score"] ??
          item["battleScore"] ??
          baseDetail["battleScore"] ??
          hunting["score"]),
      kills: toInt(item["iKillNum"] ??
          item["iKills"] ??
          baseDetail["iKillNum"] ??
          baseDetail["iKills"] ??
          item["killNum"] ??
          baseDetail["killNum"] ??
          item["kills"] ??
          baseDetail["kills"] ??
          item["kill"] ??
          baseDetail["kill"] ??
          hunting["killNum"]),
      deaths: toInt(item["iDeadNum"] ??
          item["iDeaths"] ??
          baseDetail["iDeadNum"] ??
          baseDetail["iDeaths"] ??
          item["deadNum"] ??
          baseDetail["deadNum"] ??
          item["deaths"] ??
          baseDetail["deaths"] ??
          item["death"] ??
          baseDetail["death"] ??
          item["dieCount"] ??
          baseDetail["dieCount"] ??
          hunting["deadNum"]),
      partitionDetails: partitionDetails,
      equipments: equipments,
    );
  }

  List<Map<String, dynamic>> _extractPlayerNodes(Map<String, dynamic> payload) {
    const List<String> candidateKeys = <String>[
      "list",
      "playerList",
      "users",
      "memberList",
      "teamList",
      "userList",
    ];
    for (final String key in candidateKeys) {
      final List<dynamic> rawList = _asList(payload[key]);
      if (rawList.isEmpty) continue;
      final List<Map<String, dynamic>> list = rawList
          .map((dynamic e) => _asMap(e))
          .where((Map<String, dynamic> e) => e.isNotEmpty)
          .toList();
      if (list.isNotEmpty) {
        return list;
      }
    }
    final Map<String, dynamic> loginUser = _asMap(payload["loginUserDetail"]);
    if (loginUser.isNotEmpty) {
      return <Map<String, dynamic>>[loginUser];
    }
    return const <Map<String, dynamic>>[];
  }

  List<MatchPartitionDetail> _parsePartitionDetails(
      dynamic raw, Map<String, String> partitionAreaMap) {
    final List<MatchPartitionDetail> out = <MatchPartitionDetail>[];
    final List<dynamic> source = _asList(raw);
    if (source.isEmpty) return out;
    for (final dynamic item in source) {
      final Map<String, dynamic> node = _asMap(item);
      if (node.isEmpty) continue;
      final String areaId = _firstTextFromMap(
          node, const <String>["areaId", "iAreaId", "id"], "");
      if (areaId.isEmpty) continue;
      final int usedTime = int.tryParse("${node["usedTime"] ?? 0}".trim()) ?? 0;
      final String areaNameFromDetail = _decodeText(_firstTextFromMap(
          node, const <String>["areaName", "name", "partitionName"], ""));
      final String areaName = areaNameFromDetail.isNotEmpty
          ? areaNameFromDetail
          : partitionAreaMap[areaId] ?? "区域$areaId";
      out.add(MatchPartitionDetail(
        areaId: areaId,
        areaName: areaName,
        usedTime: usedTime,
      ));
    }
    return out;
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map) {
      final Map<String, dynamic> out = <String, dynamic>{};
      value.forEach((dynamic key, dynamic v) {
        out["${key ?? ""}"] = v;
      });
      return out;
    }
    if (value is String) {
      final String text = value.trim();
      if (text.isEmpty) return <String, dynamic>{};
      try {
        final dynamic decoded = jsonDecode(text);
        if (decoded is Map) {
          final Map<String, dynamic> out = <String, dynamic>{};
          decoded.forEach((dynamic key, dynamic value) {
            out["${key ?? ""}"] = value;
          });
          return out;
        }
      } catch (_) {
        return <String, dynamic>{};
      }
    }
    return <String, dynamic>{};
  }

  List<dynamic> _asList(dynamic value) {
    if (value is List) {
      return value;
    }
    if (value is String) {
      final String text = value.trim();
      if (text.isEmpty) return const <dynamic>[];
      try {
        final dynamic decoded = jsonDecode(text);
        if (decoded is List) {
          return decoded;
        }
      } catch (_) {
        return const <dynamic>[];
      }
    }
    return const <dynamic>[];
  }

  String _firstTextFromMap(
      Map<String, dynamic> source, List<String> keys, String fallback) {
    for (final String key in keys) {
      final String value = "${source[key] ?? ""}".trim();
      if (value.isNotEmpty) return value;
    }
    return fallback;
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
    const String host = "https://nzm.playerhub.qq.com/";
    if (value.startsWith("/")) {
      return "${host.substring(0, host.length - 1)}$value";
    }
    return "$host$value";
  }
}

