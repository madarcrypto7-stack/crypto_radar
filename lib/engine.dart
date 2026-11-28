import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'binance_service.dart';
import 'btc_flux.dart';
import 'icon_store.dart';
import 'indicators.dart';
import 'models.dart';
import 'native_bridge.dart';
import 'pipeline.dart';
import 'simulator.dart';
import 'strategy3m.dart';
import 'trend.dart';

final RadarEngine engine = RadarEngine();

class RadarEngine extends ChangeNotifier {
  RadarEngine() {
    sim = Simulator((s) => tokens[s]?.price, _onSimChange, _simNotify);
  }

  // Reglages
  Market market = Market.spot;
  Sensitivity sens = Sensitivity.medium;
  int topN = 100;
  SortKey sortKey = SortKey.score;
  bool notifOn = true;
  bool keepAlive = false;
  bool autoTrade = false;
  bool btcFilter = false;
  BtcMode btcMode = BtcMode.short;
  bool volLive = true;
  bool showPrice = false;
  bool btcReversalNotif = true;
  bool favoritesOnly = false;
  double riskPct = 1.0;
  int presetIndex = 1;
  Set<String> favorites = <String>{};

  // Etat
  final Map<String, TokenData> tokens = <String, TokenData>{};
  List<TokenData> ranking = <TokenData>[];
  final List<AlertItem> alerts = <AlertItem>[];
  Trend btcTrend = Trend.unknown;
  bool btcProvisional = false;
  bool _btcBusy = false;
  List<Candle>? btcDaily;

  // Tableau de bord multi-echelles du flux BTC (15m ... 12h)
  final Map<String, List<Candle>> _btcMtf = <String, List<Candle>>{};
  BtcFluxIndex? btcIdx;
  double btcIdxDelta = 0;
  final List<int> _idxT = <int>[];
  final List<double> _idxV = <double>[];
  Timer? _mtfTimer;
  Timer? _iconTimer;
  bool _mtfBusy = false;

  // Flux de l'or (XAU) : memes 7 echelles que le BTC
  final Map<String, List<Candle>> _xauMtf = <String, List<Candle>>{};
  BtcFluxIndex? xauIdx;
  String xauSymbol = '';
  MapEntry<Market, String>? _xauPref;
  bool _xauBusy = false;
  String btcInfo = 'Flux BTC : calcul en cours...';
  bool connected = false;
  String status = 'Initialisation...';
  String? errorLog;
  late final Simulator sim;

  SharedPreferences? _p;
  BinanceService _api = BinanceService(Market.spot);
  Timer? _loop;
  Timer? _klineTimer;
  Timer? _btcTimer;
  Timer? _todayTimer;
  bool _todayBusy = false;

  // Strategie 3m : barriere BTC + strategie independante par jeton
  bool tokenStratOn = false;
  bool useStratExits = false;
  StratP tokP = const StratP();
  int topK = 10;
  int reentryMin = 60; // delai avant rachat d'un jeton apres sa sortie (minutes)

  // Selection de classement des bureaux : long = jetons qui montent depuis le bas ; short = jetons excites en haut
  bool selFilterOn = true;
  int selE = 3; // nombre de jetons exceptionnels (les plus actifs dans le sens)
  _Sel _selFastUp = _Sel.empty();
  _Sel _selFastDn = _Sel.empty();
  _Sel _selSlowUp = _Sel.empty();
  _Sel _selSlowDn = _Sel.empty();
  Set<String> _topSet = <String>{};
  bool _selReady = false;

  // Barrieres de flux BTC (3m, 15m, 1h) : impulsion + croisement MACD
  final Map<String, BarrierCfg> bcfg = <String, BarrierCfg>{for (final tf in kBarrierTfs) tf: defaultBarrierCfg(tf)};
  final Map<String, BarrierState> barriers = <String, BarrierState>{
    for (final tf in kBarrierTfs) tf: const BarrierState.closed(),
  };
  final Map<String, int> _bCross = <String, int>{};
  final Map<String, int> _bScan = <String, int>{};
  final Map<String, int> _bLast = <String, int>{};
  final Set<String> _bBusy = <String>{};
  final Map<String, LoopMachine> _mach = <String, LoopMachine>{};
  final Map<String, int> _machT = <String, int>{};
  Timer? _barrierTimer;
  final Map<String, _Armed> _armed = <String, _Armed>{};
  final Map<String, int> _tokCool = <String, int>{};
  final Map<String, int> _scanCool = <String, int>{};
  int _armedBusy = 0;
  Set<String> _poolSyms = <String>{};
  int _autoQueue = 0;
  double maxExposure = 1.0;
  StreamSubscription<dynamic>? _wsSub;
  WebSocketChannel? _channel;
  int _gen = 0;
  bool _reconnectPending = false;
  int _wsFails = 0;
  int _lastWsMs = 0;
  int _lastPollMs = 0;
  int _lastDataMs = 0;
  int _lastSwitchMs = 0;
  bool _connecting = false;
  int wsMsgs = 0;
  String lastNetErr = '';
  bool _polling = false;

  static const Set<String> _stables = <String>{
    'USDC', 'FDUSD', 'TUSD', 'BUSD', 'USDP', 'DAI', 'AEUR', 'EUR', 'USDE', 'XUSD',
    'PYUSD', 'USD1', 'UST', 'USDS', 'BFUSD',
  };

  bool _ok(String s) {
    if (!s.endsWith('USDT') || s.contains('_')) return false;
    final b = s.substring(0, s.length - 4);
    return b.isNotEmpty && !_stables.contains(b);
  }

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    _p = p;
    market = Market.values[_ci(p.getInt('market') ?? 0, 0, 1)];
    sens = Sensitivity.values[_ci(p.getInt('sens') ?? 1, 0, 3)];
    topN = p.getInt('topN') ?? 100;
    notifOn = p.getBool('notifOn') ?? true;
    keepAlive = p.getBool('keepAlive') ?? false;
    autoTrade = p.getBool('autoTrade') ?? false;
    btcFilter = p.getBool('btcFilter') ?? false;
    btcMode = BtcMode.values[_ci(p.getInt('btcMode') ?? 0, 0, 1)];
    maxExposure = p.getDouble('maxExp') ?? 1.0;
    tokenStratOn = p.getBool('tokStrat') ?? false;
    useStratExits = p.getBool('stratExits') ?? false;
    topK = p.getInt('topK') ?? 10;
    reentryMin = p.getInt('reentryMin') ?? 60;
    selFilterOn = p.getBool('selOn') ?? true;
    selE = p.getInt('selE') ?? 3;
    sim.cooldownMs = reentryMin * 60000;
    try {
      final t = p.getString('tokP');
      if (t != null) tokP = StratP.fromJson(jsonDecode(t) as Map<String, dynamic>);
      for (final tf in kBarrierTfs) {
        final j = p.getString('bcfg_$tf');
        if (j != null) {
          bcfg[tf] = BarrierCfg.fromJson(tf, jsonDecode(j) as Map<String, dynamic>);
        } else if (tf == '3m') {
          // migration des anciens reglages de la barriere 3m
          final c = defaultBarrierCfg('3m');
          c.enabled = p.getBool('barrierOn') ?? false;
          c.durMin = p.getInt('barrierMin') ?? 45;
          final b = p.getString('btcP');
          if (b != null) c.p = StratP.fromJson(jsonDecode(b) as Map<String, dynamic>);
          bcfg['3m'] = c;
        }
      }
    } catch (_) {}
    sim.maxExposure = maxExposure;
    volLive = p.getBool('volToday') ?? true;
    showPrice = p.getBool('showPrice') ?? false;
    btcReversalNotif = p.getBool('btcRev') ?? true;
    favoritesOnly = p.getBool('favOnly') ?? false;
    riskPct = p.getDouble('riskPct') ?? 1.0;
    presetIndex = _ci(p.getInt('preset') ?? 1, 0, kPresets.length - 1);
    favorites = (p.getStringList('fav') ?? <String>[]).toSet();
    sim.load(p.getString('sim'));
    // Demarrage differe : l'interface s'affiche d'abord, le reseau ensuite.
    Future<void>.delayed(const Duration(seconds: 2), () {
      NativeBridge.requestPermission();
      if (keepAlive) NativeBridge.startService();
    });
    unawaited(Future<void>.delayed(const Duration(milliseconds: 600), () => start()).catchError((Object e) {
      status = 'Erreur de demarrage : $e';
      errorLog = '${errorLog ?? ''}\n[start] $e';
      notifyListeners();
    }));
  }

  void clearError() {
    errorLog = null;
    notifyListeners();
  }

  int _ci(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

  void _save() {
    final p = _p;
    if (p == null) return;
    p.setInt('market', market.index);
    p.setInt('sens', sens.index);
    p.setInt('topN', topN);
    p.setBool('notifOn', notifOn);
    p.setBool('keepAlive', keepAlive);
    p.setBool('autoTrade', autoTrade);
    p.setBool('btcFilter', btcFilter);
    p.setInt('btcMode', btcMode.index);
    p.setDouble('maxExp', maxExposure);
    p.setBool('tokStrat', tokenStratOn);
    p.setBool('stratExits', useStratExits);
    p.setInt('topK', topK);
    p.setInt('reentryMin', reentryMin);
    p.setBool('selOn', selFilterOn);
    p.setInt('selE', selE);
    p.setString('tokP', jsonEncode(tokP.toJson()));
    for (final tf in kBarrierTfs) {
      p.setString('bcfg_$tf', jsonEncode(bcfg[tf]!.toJson()));
    }
    p.setBool('volToday', volLive);
    p.setBool('showPrice', showPrice);
    p.setBool('btcRev', btcReversalNotif);
    p.setBool('favOnly', favoritesOnly);
    p.setDouble('riskPct', riskPct);
    p.setInt('preset', presetIndex);
    p.setStringList('fav', favorites.toList());
  }

  void _simNotify(String title, String body) {
    if (notifOn) NativeBridge.notify(title, body);
  }

  void _onSimChange() {
    _p?.setString('sim', sim.encode());
  }

  // ---------------------------------------------------------------- reseau

  /// Fermeture silencieuse : une socket deja fermee ne doit pas remonter d'erreur non geree.
  void _closeChannel(WebSocketChannel? ch) {
    if (ch == null) return;
    try {
      unawaited(ch.sink.close().catchError((Object _) {}));
    } catch (_) {}
  }

  void _stop() {
    _loop?.cancel();
    _klineTimer?.cancel();
    _btcTimer?.cancel();
    _todayTimer?.cancel();
    _mtfTimer?.cancel();
    _iconTimer?.cancel();
    _barrierTimer?.cancel();
    _wsSub?.cancel();
    _wsSub = null;
    _closeChannel(_channel);
    _channel = null;
    _reconnectPending = false;
  }

  Future<void> start() async {
    _gen++;
    final gen = _gen;
    _stop();
    _api = BinanceService(market);
    tokens.clear();
    ranking = <TokenData>[];
    connected = false;
    btcTrend = Trend.unknown;
    btcProvisional = false;
    btcDaily = null;
    _btcMtf.clear();
    btcIdx = null;
    _xauMtf.clear();
    for (final tf in kBarrierTfs) {
      barriers[tf] = const BarrierState.closed();
    }
    _mach.clear();
    _machT.clear();
    _armed.clear();
    xauIdx = null;
    status = 'Chargement du marche ${market.label}...';
    notifyListeners();
    try {
      final snap = await _api.fetch24h();
      if (gen != _gen) return;
      _applySnapshot(snap);
      _syncIcons();
      status = 'Marche charge (${tokens.length} paires USDT)';
    } catch (e) {
      status = 'Erreur reseau : $e (nouvelle tentative dans 10 s)';
      lastNetErr = '$e'.length > 140 ? '$e'.substring(0, 140) : '$e';
      unawaited(Future<void>.delayed(const Duration(seconds: 10), () {
        if (gen == _gen && tokens.isEmpty) start();
      }));
    }
    if (gen != _gen) return;
    _lastWsMs = DateTime.now().millisecondsSinceEpoch;
    _connectWs(gen);
    _loop = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    unawaited(_loadKlines(gen, true));
    _klineTimer = Timer.periodic(const Duration(minutes: 30), (_) => _loadKlines(_gen, true));
    _todayTimer = Timer.periodic(const Duration(seconds: 60), (_) => _refreshToday(_gen));
    unawaited(_refreshBtc(gen));
    _mtfTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _refreshBtcMtf(_gen);
      _refreshXau(_gen);
    });
    unawaited(_refreshBtcMtf(gen));
    unawaited(_refreshXau(gen));
    _barrierTimer = Timer.periodic(const Duration(seconds: 15), (_) => _barrierTick(_gen));
    _iconTimer = Timer.periodic(const Duration(hours: 6), (_) => _syncIcons());
    _btcTimer = Timer.periodic(const Duration(seconds: 30), (_) => _refreshBtc(_gen));
    notifyListeners();
  }

  void _applySnapshot(List<Map<String, dynamic>> snap) {
    for (final m in snap) {
      final s = m['symbol'] as String;
      _applyTick(
        s,
        toD(m['lastPrice']),
        toD(m['openPrice']),
        toD(m['highPrice']),
        toD(m['lowPrice']),
        toD(m['quoteVolume']),
      );
    }
  }

  /// Mode secours : si le WebSocket ne livre rien pendant 20 s, on interroge l'API HTTP toutes les 5 s.
  Future<void> _pollRest(int gen) async {
    _polling = true;
    try {
      final snap = await _api.fetch24h();
      if (gen != _gen) return;
      _applySnapshot(snap);
      _lastPollMs = DateTime.now().millisecondsSinceEpoch;
      _lastDataMs = _lastPollMs;
    } catch (e) {
      lastNetErr = 'HTTP : $e'.length > 140 ? 'HTTP : $e'.substring(0, 140) : 'HTTP : $e';
      _lastPollMs = DateTime.now().millisecondsSinceEpoch;
    } finally {
      _polling = false;
    }
  }

  bool get fallback =>
      _lastPollMs > _lastWsMs && DateTime.now().millisecondsSinceEpoch - _lastWsMs > 20000;

  Future<void> _connectWs(int gen) async {
    if (gen != _gen || _connecting) return;
    _connecting = true;
    _reconnectPending = false;
    try {
      _wsSub?.cancel();
      final ch = WebSocketChannel.connect(Uri.parse(_api.wsUrl));
      _channel = ch;
      await ch.ready.timeout(const Duration(seconds: 10));
      if (gen != _gen) {
        _closeChannel(ch);
        return;
      }
      _wsFails = 0;
      _wsSub = ch.stream.listen(
        (dynamic data) {
          connected = true;
          _onWs(data);
        },
        onError: (Object _) => _reconnect(gen),
        onDone: () => _reconnect(gen),
        cancelOnError: true,
      );
    } catch (e) {
      _wsFails++;
      lastNetErr = '$e'.length > 140 ? '$e'.substring(0, 140) : '$e';
      if (_wsFails % 2 == 0) {
        if (market == Market.spot) {
          BinanceService.alt = !BinanceService.alt;
        } else {
          BinanceService.fVariant = (BinanceService.fVariant + 1) % 3;
        }
      }
      connected = false;
      status = 'Hors ligne : verifiez la connexion Internet (nouvelle tentative automatique)';
      notifyListeners();
      _reconnect(gen);
    } finally {
      _connecting = false;
    }
  }

  void _reconnect(int gen) {
    connected = false;
    if (gen != _gen || _reconnectPending) return;
    _reconnectPending = true;
    final secs = math.min(30, 3 + _wsFails * 3);
    Future<void>.delayed(Duration(seconds: secs), () {
      if (gen == _gen) _connectWs(gen);
    });
  }

  void _onWs(dynamic data) {
    try {
      dynamic j = jsonDecode(data as String);
      if (j is Map<String, dynamic> && j['data'] != null) j = j['data'];
      if (j is List<dynamic>) {
        final now = DateTime.now().millisecondsSinceEpoch;
        _lastWsMs = now;
        _lastDataMs = now;
        wsMsgs++;
        for (final m in j) {
          final mm = m as Map<String, dynamic>;
          _applyTick(
            mm['s'] as String,
            toD(mm['c']),
            toD(mm['o']),
            toD(mm['h']),
            toD(mm['l']),
            toD(mm['q']),
          );
        }
      }
    } catch (_) {}
  }

  /// Etat de la connexion, affiche sous le classement (diagnostic).
  String get netStatus {
    final now = DateTime.now().millisecondsSinceEpoch;
    final live = connected && now - _lastWsMs < 15000;
    final src = live ? 'WebSocket OK' : (fallback ? 'HTTP secours' : 'WebSocket en attente...');
    final age = _lastDataMs == 0 ? '-' : '${((now - _lastDataMs) / 1000).round()}s';
    return '${market.label} · $src · ${tokens.length} paires · maj $age · $kBuild';
  }

  void _rotateWs(int now) {
    _lastSwitchMs = now;
    if (market == Market.futures) {
      BinanceService.fVariant = (BinanceService.fVariant + 1) % 3;
    } else {
      BinanceService.alt = !BinanceService.alt;
    }
    _wsSub?.cancel();
    _wsSub = null;
    _closeChannel(_channel);
    _channel = null;
    _reconnectPending = false;
    unawaited(_connectWs(_gen));
  }

  Future<void> _loadKlines(int gen, bool force) async {
    final all = tokens.values.where((t) => t.price > 0).toList()
      ..sort((a, b) => b.quoteVol24.compareTo(a.quoteVol24));
    final set = <TokenData>{...all.take(topN)};
    for (final f in favorites) {
      final t = tokens[f];
      if (t != null) set.add(t);
    }
    final list = set.where((t) => force || !t.klinesLoaded).toList();
    for (var i = 0; i < list.length; i += 6) {
      if (gen != _gen) return;
      final batch = list.sublist(i, math.min(i + 6, list.length));
      await Future.wait(batch.map((t) async {
        try {
          final k = await _api.klines(t.symbol, '1d', 361);
          t.dailyQuoteVol = k.map((c) => c.qv).toList();
          t.dailyClose = k.map((c) => c.c).toList();
          if (k.isNotEmpty) {
            t.dailyLastT = k.last.t;
            t.todayOpen = k.last.o;
          }
          t.klinesLoaded = true;
          if (t.symbol == 'BTCUSDT') btcDaily = k;
        } catch (_) {}
      }));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// Trading automatique : l'alerte ne fait que declencher l'analyse. Le trade n'est ouvert que si les bureaux
  /// (tendance du jeton, exception rebond, flux BTC en contexte, backtest, plan ATR) valident et dans le meme sens.
  Future<void> _autoTrade(TokenData t, bool up, {String source = 'auto'}) async {
    final sel = selectionFor(t, up, slow: source == 'barrier15m' || source == 'barrier1h');
    if (!sel.ok) {
      sim.lastAutoMsg = '${t.base} : ${sel.why}';
      notifyListeners();
      return;
    }
    final left = sim.cooldownLeftMs(t.symbol);
    if (left > 0) {
      sim.lastAutoMsg = '${t.base} : rachat bloque (${(left / 60000).ceil()} min apres la derniere sortie)';
      notifyListeners();
      return;
    }
    final block = sim.autoBlockReason();
    if (block != null) {
      sim.lastAutoMsg = '${t.base} : $block';
      notifyListeners();
      return;
    }
    if (_autoQueue >= 3) {
      sim.lastAutoMsg = '${t.base} : file d analyse pleine, ignore';
      notifyListeners();
      return;
    }
    _autoQueue++;
    try {
      StratP? ex;
      var exTf = '3m';
      if (useStratExits && source != 'auto') {
        if (source.startsWith('barrier')) {
          exTf = source.substring(7);
          ex = bcfg[exTf]?.p;
        } else {
          ex = tokP;
        }
      }
      final r = await runPipeline(this, t.symbol, exits: ex, exitsTf: exTf);
      final plan = r.plan;
      if (plan == null || !r.execute) {
        final why = r.reports.isEmpty
            ? ''
            : r.reports.last.lines.where((l) => l.startsWith('✘')).take(2).join(' ');
        sim.lastAutoMsg = '${t.base} : bureaux = REJET $why';
        return;
      }
      if (plan.long != up) {
        sim.lastAutoMsg = '${t.base} : sens des bureaux (${plan.long ? 'long' : 'short'}) different de l alerte, ignore';
        return;
      }
      final tr = sim.openPlan(plan, market, source: source);
      sim.lastAutoMsg = tr == null
          ? '${t.base} : refus (${sim.lastRefusal})'
          : '${t.base} : paper trade ouvert apres validation des bureaux ($source)';
    } catch (e) {
      sim.lastAutoMsg = '${t.base} : analyse des bureaux impossible, trade ignore';
    } finally {
      _autoQueue--;
      notifyListeners();
    }
  }

  bool get anyBarrierOn => bcfg.values.any((c) => c.enabled);

  /// Echelle d'une barriere ouverte dans ce sens (priorite aux echelles longues), sinon null.
  String? openBarrierTf(bool long) {
    // La barriere la plus recente a priorite : si son sens est oppose, aucune barriere n'est ouverte dans le sens demande.
    var latest = -1;
    var dirL = 0;
    for (final tf in kBarrierTfs) {
      final b = barriers[tf]!;
      if (bcfg[tf]!.enabled && b.state == 'open' && b.sinceMs > latest) {
        latest = b.sinceMs;
        dirL = b.dir;
      }
    }
    if (dirL != (long ? 1 : -1)) return null;
    for (final tf in const <String>['1h', '15m', '3m']) {
      final b = barriers[tf]!;
      if (bcfg[tf]!.enabled && b.state == 'open' && b.dir == dirL) return tf;
    }
    return null;
  }

  /// Une barriere qui vient de remplir toutes ses conditions annule les barrieres ouvertes de sens oppose
  /// (priorite a la plus recente, meme si leur duree n'est pas ecoulee). Les ordres ouverts ne sont PAS fermes.
  void _cancelOpposite(String tf, int dir) {
    for (final o in kBarrierTfs) {
      if (o == tf) continue;
      final ob = barriers[o]!;
      if (ob.state == 'open' && ob.dir == -dir) {
        _mach[o]?.cancelled = true;
        barriers[o] = BarrierState(
          'closed',
          0,
          0,
          0,
          0.0,
          'annulee : barriere $tf ${dir == 1 ? 'LONG' : 'SHORT'} prioritaire (ordres conserves)',
        );
      }
    }
  }

  bool barrierAligned(bool long) => openBarrierTf(long) != null;

  // ------------------------------------------------------------ strategie 3m / 15m / 1h

  Future<void> _barrierTick(int gen) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    _processArmed(now);
    for (final tf in kBarrierTfs) {
      final cfg = bcfg[tf]!;
      if (!cfg.enabled) {
        if (barriers[tf]!.state != 'closed') {
          barriers[tf] = const BarrierState.closed('desactivee');
          notifyListeners();
        }
        continue;
      }
      final every = tf == '3m' ? 15000 : (tf == '15m' ? 60000 : 120000);
      if (now - (_bLast[tf] ?? 0) >= every) {
        _bLast[tf] = now;
        await _checkBarrier(tf, gen);
      }
      final scanEvery = tf == '3m' ? 120000 : (tf == '15m' ? 600000 : 1800000);
      if (barriers[tf]!.state == 'open' && autoTrade && now - (_bScan[tf] ?? 0) > scanEvery) {
        _bScan[tf] = now;
        unawaited(_barrierScan(tf));
      }
    }
  }

  /// Barriere BTC d'une echelle : boucle fermee (voir LoopMachine) :
  /// bougie d'impulsion + croisement MACD dans n'importe quel ordre = ouverture dans ce sens,
  /// puis surveillance immediate du sens inverse pour la position suivante.
  Future<void> _checkBarrier(String tf, int gen) async {
    if (_bBusy.contains(tf)) return;
    _bBusy.add(tf);
    try {
      final cfg = bcfg[tf]!;
      final k = await _api.klines('BTCUSDT', tf, 150).timeout(const Duration(seconds: 15));
      if (gen != _gen || k.length < 70) return;
      final closed = k.sublist(0, k.length - 1);
      final p = cfg.p;
      final m = macdLines(closed.map((x) => x.c).toList(), fast: p.fast, slow: p.slow, sig: p.sig);
      final n = closed.length;
      final tfMin = tfMinutes(tf);
      final tfMs = tfMin * 60000;
      final now = DateTime.now().millisecondsSinceEpoch;
      final prevB = barriers[tf]!;
      final prevDir = prevB.state == 'open' ? prevB.dir : 0;
      var mach = _mach[tf];
      Sig3m? lastSig;
      var warm = false;
      if (mach == null) {
        // Premiere analyse : on rejoue l'historique pour retrouver l'etat courant de la boucle.
        warm = true;
        mach = LoopMachine(p, math.max(1, cfg.durMin ~/ tfMin), tfMs);
        _mach[tf] = mach;
        for (var i = 1; i < n; i++) {
          final s = mach.step(closed, m, i);
          if (s != null) lastSig = s;
        }
      } else {
        final since = _machT[tf] ?? 0;
        for (var i = 1; i < n; i++) {
          if (closed[i].t > since) {
            final s = mach.step(closed, m, i);
            if (s != null) lastSig = s;
          }
        }
      }
      _machT[tf] = closed.last.t;
      final expiry = mach.openT + (cfg.durMin + tfMin) * 60000;
      final active = mach.dir != 0 && !mach.cancelled && now < expiry; // duree d'ouverture ecoulee : la boucle continue, mais sans autoriser de trades
      final note = loopWatchNote(mach, p);
      BarrierState b;
      if (active) {
        final openT0 = mach.openT;
        final oi = closed.indexWhere((x) => x.t == openT0);
        final pct = oi >= 0 && closed[oi].o > 0 ? (closed[oi].c / closed[oi].o - 1) * 100 : 0.0;
        b = BarrierState('open', mach.dir, mach.openT, expiry, pct, 'inversion attendue -> $note');
      } else {
        final armed = mach.hasImp(1) || mach.hasImp(-1) || mach.hasCross(1) || mach.hasCross(-1);
        b = BarrierState(armed ? 'armed' : 'closed', 0, 0, 0, 0.0, mach.dir != 0 ? 'barriere terminee · inversion attendue -> $note' : note);
      }
      barriers[tf] = b;
      // Annonce d'une ouverture ou d'une inversion
      final ls = lastSig;
      if (ls != null && mach.dir == ls.dir && (!warm || ls.crossIdx >= n - 2)) {
        _bScan[tf] = 0;
        final up = ls.dir == 1;
        final ii = ls.impulseIdx < 0 ? 0 : (ls.impulseIdx > n - 1 ? n - 1 : ls.impulseIdx);
        final ic = closed[ii];
        final pct = ic.o > 0 ? (ic.c / ic.o - 1) * 100 : 0.0;
        alerts.insert(
          0,
          AlertItem(
            symbol: 'BTCUSDT',
            base: 'BTC',
            up: up,
            score: 0,
            move5m: pct,
            events: 0,
            price: tokens['BTCUSDT']?.price ?? 0,
            time: now,
            title: '🚧 Barriere BTC $tf ${up ? '↑ LONG' : '↓ SHORT'} ${prevDir != 0 && prevDir != ls.dir ? '(inversion)' : 'ouverte'}',
            body: 'Bougie $tf ${pct.toStringAsFixed(2)} % + croisement MACD · jetons les plus actifs autorises ${fmtDur(cfg.durMin)} · '
                'puis surveillance de l inversion',
          ),
        );
        if (alerts.length > 50) alerts.removeLast();
        _cancelOpposite(tf, ls.dir);
      }
      notifyListeners();
    } catch (e) {
      final t = '$e';
      lastNetErr = t.length > 140 ? t.substring(0, 140) : t;
    } finally {
      _bBusy.remove(tf);
    }
  }

  /// Barriere ouverte : les jetons les plus actifs dans le meme sens passent par les bureaux (preparation habituelle).
  /// 3m : activite courte (score, volume, vitesse). 15m / 1h : tendance 24 h et volume (trades de longue duree).
  Future<void> _barrierScan(String tf) async {
    final b0 = barriers[tf]!;
    if (!autoTrade || b0.state != 'open') return;
    final up = b0.dir == 1;
    final now = DateTime.now().millisecondsSinceEpoch;
    double act(TokenData t) => tf == '3m'
        ? t.score + 8 * math.max(0.0, t.volRatio - 1) + 6 * t.move5m.abs()
        : t.change24.abs() * math.log(t.quoteVol24 + 10) / math.ln10;
    bool dirOk(TokenData t) => tf == '3m'
        ? (t.direction == (up ? 'up' : 'down') && (up ? t.move5m > 0 : t.move5m < 0))
        : (up ? t.change24 > 0 : t.change24 < 0);
    final cand = ranking
        .where((t) => t.symbol != 'BTCUSDT' && dirOk(t) && selectionFor(t, up, slow: tf != '3m').ok)
        .toList()
      ..sort((a, b) => act(b).compareTo(act(a)));
    final coolMs = tf == '3m' ? 600000 : 3600000;
    var n = 0;
    for (final t in cand) {
      if (barriers[tf]!.state != 'open' || n >= topK) break;
      if (sim.open.any((x) => x.symbol == t.symbol)) continue;
      if (sim.cooldownLeftMs(t.symbol) > 0) continue;
      final key = '$tf${t.symbol}';
      if (now - (_scanCool[key] ?? 0) < coolMs) continue;
      _scanCool[key] = now;
      n++;
      await _autoTrade(t, up, source: 'barrier$tf');
    }
  }

  void _onImpulse(TokenData t, bool up, int now) {
    if (!_poolSyms.contains(t.symbol)) return;
    if (now - (_tokCool[t.symbol] ?? 0) < 900000) return;
    if (_armed.length >= 40) return;
    _armed[t.symbol] = _Armed(up ? 1 : -1, now + (tokP.win + 1) * 180000);
  }

  void _processArmed(int now) {
    if (!tokenStratOn) {
      _armed.clear();
      return;
    }
    final dead = <String>[];
    _armed.forEach((sym, a) {
      if (now > a.expireMs) {
        dead.add(sym);
        return;
      }
      if (now - a.lastCheck >= 20000 && _armedBusy < 3) {
        a.lastCheck = now;
        _armedBusy++;
        unawaited(_checkArmed(sym, a));
      }
    });
    for (final d in dead) {
      _armed.remove(d);
    }
  }

  Future<void> _checkArmed(String sym, _Armed a) async {
    try {
      final k = await _api.klines(sym, '3m', 120).timeout(const Duration(seconds: 15));
      if (k.length < 70) return;
      final closed = k.sublist(0, k.length - 1);
      final p = tokP;
      final m = macdLines(closed.map((x) => x.c).toList(), fast: p.fast, slow: p.slow, sig: p.sig);
      final n = closed.length;
      // Meme procedure que la barriere : impulsion et croisement MACD dans n'importe quel ordre.
      final mach = LoopMachine(p, 20, 180000);
      Sig3m? last;
      for (var i = 1; i < n; i++) {
        final s = mach.step(closed, m, i);
        if (s != null) last = s;
      }
      if (last != null && last.dir == a.dir && last.crossIdx >= n - 2) {
        _armed.remove(sym);
        final t = tokens[sym];
        if (t != null) _tokenTrigger(t, a.dir == 1);
        return;
      }
    } catch (_) {
    } finally {
      _armedBusy--;
    }
  }

  void _tokenTrigger(TokenData t, bool up) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _tokCool[t.symbol] = now;
    alerts.insert(
      0,
      AlertItem(
        symbol: t.symbol,
        base: t.base,
        up: up,
        score: t.score,
        move5m: t.move5m,
        events: t.dirEvents,
        price: t.price,
        time: now,
        title: '⚡ 3m ${up ? '↑' : '↓'} ${t.base} : impulsion + croisement MACD',
        body: 'Declencheur independant (seuil ${tokP.impulse} %) · prix ${t.price}',
      ),
    );
    if (alerts.length > 50) alerts.removeLast();
    if (autoTrade) unawaited(_autoTrade(t, up, source: 'token3m'));
    notifyListeners();
  }

  void setBarrierEnabled(String tf, bool v) {
    _mach.remove(tf);
    _machT.remove(tf);
    bcfg[tf]!.enabled = v;
    if (!v) barriers[tf] = const BarrierState.closed('desactivee');
    _bLast[tf] = 0;
    _save();
    notifyListeners();
    if (v) unawaited(_barrierTick(_gen));
  }

  void setBarrierP(String tf, StratP p) {
    _mach.remove(tf);
    _machT.remove(tf);
    bcfg[tf]!.p = p;
    _save();
    notifyListeners();
  }

  void setBarrierDur(String tf, int min) {
    _mach.remove(tf);
    _machT.remove(tf);
    final c = bcfg[tf]!;
    c.durMin = min < c.minDur ? c.minDur : (min > c.maxDur ? c.maxDur : min);
    _save();
    notifyListeners();
  }

  void setTokenStrat(bool v) {
    tokenStratOn = v;
    if (!v) _armed.clear();
    _save();
    notifyListeners();
  }

  void setUseStratExits(bool v) {
    useStratExits = v;
    _save();
    notifyListeners();
  }

  void setTokP(StratP p) {
    tokP = p;
    _save();
    notifyListeners();
  }

  void setTopK(int v) {
    topK = v;
    _save();
    notifyListeners();
  }

  void setReentryMin(int v) {
    reentryMin = v;
    sim.cooldownMs = v * 60000;
    _save();
    notifyListeners();
  }

  /// Applique un jeu de parametres issu de l'optimisation (barriere d'une echelle ou strategie par jeton).
  void applyOptimized(String tf, bool isBarrier, StratP p) {
    if (isBarrier) {
      bcfg[tf]!.p = p;
      _mach.remove(tf);
      _machT.remove(tf);
    } else {
      tokP = p;
    }
    useStratExits = true;
    _save();
    notifyListeners();
  }

  // ------------------------------------------------------------ selection de classement des bureaux

  bool _isTop(TokenData t, double p80) => t.rangePos >= 0.75 || (t.change24 >= p80 && t.change24 > 3);

  double _upAct(TokenData t) => t.move5m > 0
      ? (t.direction == 'up' ? t.score : 0.0) + 8 * math.max(0.0, t.volRatio - 1) + 6 * t.move5m
      : 0.0;
  double _dnAct(TokenData t) => t.move5m < 0
      ? (t.direction == 'down' ? t.score : 0.0) + 8 * math.max(0.0, t.volRatio - 1) + 6 * (-t.move5m)
      : 0.0;
  double _lv(TokenData t) => math.log(t.quoteVol24 + 10) / math.ln10;
  // trades longs : mouvement depuis le bas de la plage / repli depuis le haut de la plage, pondere par le volume
  double _slowUp(TokenData t) => t.low24 > 0 && t.price > t.low24 ? (t.price / t.low24 - 1) * 100 * _lv(t) : 0.0;
  double _slowDn(TokenData t) => t.high24 > 0 && t.price < t.high24 ? (1 - t.price / t.high24) * 100 * _lv(t) : 0.0;

  _Sel _mk(List<TokenData> excBase, List<TokenData> thrBase, double Function(TokenData) act) {
    final vals = thrBase.map(act).where((v) => v > 0).toList()..sort();
    final thr = vals.isEmpty ? double.infinity : vals[math.min(vals.length - 1, (vals.length * 0.6).floor())];
    final ranked = excBase.where((t) => act(t) > 0).toList()..sort((a, b) => act(b).compareTo(act(a)));
    return _Sel(thr, <String>{for (final t in ranked.take(selE)) t.symbol});
  }

  void _computeSel(List<TokenData> pool) {
    if (!selFilterOn || pool.length < 10) {
      _selReady = false;
      return;
    }
    final chg = pool.map((t) => t.change24).toList()..sort();
    final p80 = chg[math.min(chg.length - 1, (chg.length * 0.8).floor())];
    final tops = pool.where((t) => _isTop(t, p80)).toList();
    final nonTop = pool.where((t) => !_isTop(t, p80)).toList();
    _topSet = <String>{for (final t in tops) t.symbol};
    // Long : on ecarte les jetons en haut ; parmi les autres, filtre d'activite vers le haut (+ les plus actifs sont toujours retenus)
    _selFastUp = _mk(nonTop, nonTop, _upAct);
    _selSlowUp = _mk(nonTop, nonTop, _slowUp);
    // Short : on surveille les jetons en haut ; filtre d'activite vers le bas (+ les plus actifs vers le bas sont toujours retenus)
    _selFastDn = _mk(pool, tops, _dnAct);
    _selSlowDn = _mk(pool, tops, _slowDn);
    _selReady = true;
  }

  /// Selection de classement des bureaux.
  /// LONG : pas les jetons deja en haut (excites, ils se preparent a la baisse) ; on suit ceux qui montent depuis le bas,
  ///        en filtrant les moins actifs vers le haut (sauf les jetons les plus actifs en mouvement positif).
  /// SHORT : on surveille les jetons en haut, deja excites et prets a chuter, en filtrant les moins actifs vers le bas
  ///        (sauf les jetons les plus actifs en mouvement negatif).
  SelResult selectionFor(TokenData t, bool up, {bool slow = false}) {
    if (!selFilterOn) return SelResult(true, 'filtre de classement desactive');
    if (!_selReady) return SelResult(true, 'classement en cours de calcul');
    final pos = (t.rangePos * 100).round();
    final top = _topSet.contains(t.symbol);
    if (up) {
      final s = slow ? _selSlowUp : _selFastUp;
      final a = slow ? _slowUp(t) : _upAct(t);
      if (top) return SelResult(false, 'LONG refuse : jeton deja en haut ($pos % de la plage 24h), excite, il se prepare a la baisse');
      if (s.exc.contains(t.symbol)) return SelResult(true, 'LONG : parmi les $selE jetons les plus actifs vers le haut');
      if (a <= 0) return SelResult(false, 'LONG refuse : aucun mouvement vers le haut');
      if (a < s.thr) return SelResult(false, 'LONG refuse : mouvement vers le haut trop peu actif (filtre)');
      if (t.rangePos > 0.65) return SelResult(false, 'LONG refuse : deja haut dans la plage 24h ($pos %)');
      return SelResult(true, 'LONG : monte depuis le bas ($pos % de la plage 24h), mouvement actif');
    }
    final s = slow ? _selSlowDn : _selFastDn;
    final a = slow ? _slowDn(t) : _dnAct(t);
    if (s.exc.contains(t.symbol)) return SelResult(true, 'SHORT : parmi les $selE jetons les plus actifs vers le bas');
    if (!top) return SelResult(false, 'SHORT refuse : jeton pas en haut ($pos % de la plage 24h), on surveille les jetons deja excites');
    if (a <= 0) return SelResult(false, 'SHORT refuse : aucun mouvement vers le bas');
    if (a < s.thr) return SelResult(false, 'SHORT refuse : mouvement vers le bas trop peu actif (filtre)');
    return SelResult(true, 'SHORT : excite en haut ($pos % de la plage 24h), il se prepare a chuter');
  }

  void setSelFilter(bool v) {
    selFilterOn = v;
    if (!v) _selReady = false;
    _save();
    notifyListeners();
  }

  void setSelE(int v) {
    selE = v;
    _save();
    notifyListeners();
  }

  void setMaxExposure(double v) {
    maxExposure = v;
    sim.maxExposure = v;
    _save();
    notifyListeners();
  }

  void _announceReversal(Trend nt) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final bull = nt == Trend.bull;
    final title = bull ? '🔄 BTC : renversement HAUSSIER → mode LONG' : '🔄 BTC : renversement BAISSIER → mode SHORT';
    final body = bull
        ? 'Les operations long sont de nouveau autorisees.'
        : (market == Market.futures ? 'Les operations short sont autorisees (Futures).' : 'Spot : attente, pas de short possible.');
    alerts.insert(
      0,
      AlertItem(
        symbol: 'BTCUSDT',
        base: 'BTC',
        up: bull,
        score: 0,
        move5m: 0,
        events: 0,
        price: tokens['BTCUSDT']?.price ?? 0,
        time: now,
        title: title,
        body: body,
      ),
    );
    if (alerts.length > 50) alerts.removeLast();
  }

  void setShowPrice(bool v) {
    showPrice = v;
    _save();
    notifyListeners();
  }

  void setVolLive(bool v) {
    volLive = v;
    for (final t in tokens.values) {
      t.volVar.clear();
    }
    _save();
    notifyListeners();
  }

  void setBtcFilter(bool v) {
    btcFilter = v;
    _save();
    notifyListeners();
  }

  void setBtcReversalNotif(bool v) {
    btcReversalNotif = v;
    _save();
    notifyListeners();
  }

  void _applyToday(TokenData t, List<Candle> k) {
    if (k.isEmpty || t.dailyQuoteVol.isEmpty || t.dailyClose.isEmpty) return;
    final today = k.last;
    final last = t.dailyQuoteVol.length - 1;
    if (today.t != t.dailyLastT && k.length >= 2) {
      // Nouveau jour UTC : on cloture la bougie precedente et on ajoute celle du jour.
      final y = k[k.length - 2];
      t.dailyQuoteVol[last] = y.qv;
      t.dailyClose[t.dailyClose.length - 1] = y.c;
      t.dailyQuoteVol.add(today.qv);
      t.dailyClose.add(today.c);
      if (t.dailyQuoteVol.length > 400) {
        t.dailyQuoteVol.removeAt(0);
        t.dailyClose.removeAt(0);
      }
    } else {
      t.dailyQuoteVol[last] = today.qv;
      t.dailyClose[t.dailyClose.length - 1] = today.c;
    }
    t.dailyLastT = today.t;
    t.todayOpen = today.o;
  }

  /// Rafraichit chaque minute la bougie du jour (volume et ouverture) des jetons affiches.
  Future<void> _refreshToday(int gen) async {
    if (_todayBusy) return;
    _todayBusy = true;
    try {
      final list = ranking.where((t) => t.klinesLoaded).toList();
      for (var i = 0; i < list.length; i += 6) {
        if (gen != _gen) return;
        final batch = list.sublist(i, math.min(i + 6, list.length));
        await Future.wait(batch.map((t) async {
          try {
            final k = await _api.klines(t.symbol, '1d', 2);
            _applyToday(t, k);
          } catch (_) {}
        }));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    } finally {
      _todayBusy = false;
    }
  }

  Future<void> refreshBtcNow() {
    _btcBusy = false;
    return _refreshBtc(_gen);
  }

  void _setBtcInfo(String v) {
    btcInfo = v;
    notifyListeners();
  }

  void _logBtcError(Object e) {
    final line = '[flux btc] $e';
    if (errorLog == null || !errorLog!.contains(line)) {
      errorLog = errorLog == null ? line : '$errorLog\n$line';
    }
  }

  /// Repli base sur les bougies journalieres de BTC (deja telechargees pour le classement).
  bool _btcFromDaily() {
    final d = btcDaily;
    if (d == null || d.length < 60) return false;
    final closes = d.map((c) => c.c).toList();
    final a = ema(closes, 20).last > ema(closes, 50).last;
    final st = supertrend(d).last == 1;
    final b = tokens['BTCUSDT'];
    if (a && st) {
      btcTrend = Trend.bull;
    } else if (!a && !st) {
      btcTrend = Trend.bear;
    } else {
      btcTrend = (b != null && b.change24 < 0) ? Trend.bear : Trend.bull;
    }
    btcProvisional = true;
    btcInfo = 'Repli journalier : EMA 1j ${a ? "↑" : "↓"} · Supertrend 1j ${st ? "↑" : "↓"} (appuyez pour recalculer)';
    return true;
  }

  Future<void> _refreshBtc(int gen) async {
    if (_btcBusy) return;
    _btcBusy = true;
    try {
      Object? lastErr;
      final mode = btcMode;
      final tf = mode.tf;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          _setBtcInfo('Flux BTC : bougies $tf (essai ${attempt + 1}/3)...');
          final k = await _api.klines('BTCUSDT', tf, 200).timeout(const Duration(seconds: 15));
          if (gen != _gen || mode != btcMode) return;
          final closes = k.map((c) => c.c).toList();
          final e7 = ema(closes, 7).last;
          final e25 = ema(closes, 25).last;
          final live = tokens['BTCUSDT']?.price ?? 0;
          final px = live > 0 ? live : closes.last;
          final gap = e25 > 0 ? (e7 - e25) / e25 * 100 : 0.0;
          final prevTrend = btcTrend;
          final wasProvisional = btcProvisional;
          if (e7 > e25 && px > e25 && gap > 0.03) {
            btcTrend = Trend.bull;
          } else if (e7 < e25 && px < e25 && gap < -0.03) {
            btcTrend = Trend.bear;
          } else if (btcTrend == Trend.unknown || btcProvisional) {
            btcTrend = e7 >= e25 ? Trend.bull : Trend.bear;
          }
          btcProvisional = false;
          if (prevTrend != Trend.unknown && !wasProvisional && btcTrend != prevTrend) {
            _announceReversal(btcTrend);
          }
          _setBtcInfo('${mode.label} · EMA7 ${e7 > e25 ? ">" : "<"} EMA25 (ecart ${gap.toStringAsFixed(2)} %) · '
              'prix ${px > e25 ? ">" : "<"} EMA25');
          return;
        } catch (e) {
          lastErr = e;
          _logBtcError(e);
          await Future<void>.delayed(const Duration(seconds: 3));
        }
      }
      if (gen != _gen) return;
      if (!_btcFromDaily()) {
        final b = tokens['BTCUSDT'];
        if (b != null && b.price > 0 && (btcTrend == Trend.unknown || btcProvisional)) {
          btcTrend = b.change24 >= 0 ? Trend.bull : Trend.bear;
          btcProvisional = true;
        }
        btcInfo = 'Provisoire (variation 24h) · erreur : $lastErr';
      }
      notifyListeners();
      Future<void>.delayed(const Duration(seconds: 20), () {
        if (gen == _gen) _refreshBtc(gen);
      });
    } catch (e) {
      _logBtcError(e);
      _setBtcInfo('Flux BTC : erreur interne : $e');
    } finally {
      _btcBusy = false;
    }
  }

  /// Telecharge les bougies BTC des 7 echelles (en parallele) toutes les 30 s.
  Future<void> _refreshBtcMtf(int gen) async {
    if (_mtfBusy) return;
    _mtfBusy = true;
    try {
      final res = await Future.wait(kBtcTfs.map<Future<MapEntry<String, List<Candle>>>>((tf) async {
        try {
          final k = await _api.klines('BTCUSDT', tf, 150).timeout(const Duration(seconds: 15));
          return MapEntry<String, List<Candle>>(tf, k);
        } catch (_) {
          return MapEntry<String, List<Candle>>(tf, <Candle>[]);
        }
      }));
      if (gen != _gen) return;
      for (final e in res) {
        if (e.value.isNotEmpty) _btcMtf[e.key] = e.value;
      }
      _recomputeBtcIdx();
      _recordIdx();
    } finally {
      _mtfBusy = false;
    }
  }

  /// Telecharge l'icone de chaque jeton dans la base locale (premier demarrage), puis verifie les mises a jour 1 fois par jour.
  void _syncIcons() {
    final list = tokens.values.toList()..sort((a, b) => b.quoteVol24.compareTo(a.quoteVol24));
    unawaited(IconStore.I.sync(list.map((t) => t.base).toList()));
  }

  /// Bougies de l'or : XAUUSDT (contrat perpetuel TradFi de Binance Futures), repli sur PAXGUSDT (spot).
  Future<void> _refreshXau(int gen) async {
    if (_xauBusy) return;
    _xauBusy = true;
    try {
      final cands = <MapEntry<Market, String>>[
        if (_xauPref != null) _xauPref!,
        const MapEntry<Market, String>(Market.futures, 'XAUUSDT'),
        const MapEntry<Market, String>(Market.spot, 'PAXGUSDT'),
      ];
      final tried = <String>{};
      for (final c in cands) {
        if (!tried.add('${c.key.index}${c.value}')) continue;
        final api = BinanceService(c.key);
        final res = await Future.wait(kBtcTfs.map<Future<MapEntry<String, List<Candle>>>>((tf) async {
          try {
            final k = await api.klines(c.value, tf, 150).timeout(const Duration(seconds: 15));
            return MapEntry<String, List<Candle>>(tf, k);
          } catch (_) {
            return MapEntry<String, List<Candle>>(tf, <Candle>[]);
          }
        }));
        if (gen != _gen) return;
        if (res.where((e) => e.value.isNotEmpty).length >= 4) {
          for (final e in res) {
            if (e.value.isNotEmpty) _xauMtf[e.key] = e.value;
          }
          _xauPref = c;
          xauSymbol = c.value;
          _recomputeXauIdx();
          return;
        }
      }
    } finally {
      _xauBusy = false;
    }
  }

  void _recomputeXauIdx() {
    if (_xauMtf.isEmpty) return;
    final live = xauSymbol == 'XAUUSDT' ? tokens['XAUUSDT']?.price : null;
    final m = <String, TfScore>{};
    for (final tf in kBtcTfs) {
      m[tf] = scoreTimeframe(tf, _xauMtf[tf] ?? <Candle>[], live);
    }
    xauIdx = buildFluxIndex(m);
  }

  /// Recalcule les scores avec le prix BTC en direct (appele chaque seconde, calcul leger).
  void _recomputeBtcIdx() {
    if (_btcMtf.isEmpty) return;
    final live = tokens['BTCUSDT']?.price;
    final m = <String, TfScore>{};
    for (final tf in kBtcTfs) {
      m[tf] = scoreTimeframe(tf, _btcMtf[tf] ?? <Candle>[], live);
    }
    btcIdx = buildFluxIndex(m);
  }

  void _recordIdx() {
    final ix = btcIdx;
    if (ix == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _idxT.add(now);
    _idxV.add(ix.index);
    while (_idxT.length > 40) {
      _idxT.removeAt(0);
      _idxV.removeAt(0);
    }
    final cut = now - 300000;
    double? ref;
    for (var i = 0; i < _idxT.length; i++) {
      if (_idxT[i] <= cut) ref = _idxV[i];
    }
    if (ref != null) btcIdxDelta = ix.index - ref;
  }

  void setBtcMode(BtcMode m) {
    if (m == btcMode) return;
    btcMode = m;
    btcProvisional = true; // le nouveau mode peut fixer la tendance librement, sans annoncer un renversement
    _save();
    notifyListeners();
    unawaited(refreshBtcNow());
  }

  // ------------------------------------------------------------- detecteur

  void _applyTick(String s, double c, double o, double h, double l, double q) {
    if (c <= 0 || !_ok(s)) return;
    final t = tokens.putIfAbsent(s, () => TokenData(s));
    t.prevPrice = t.price == 0 ? c : t.price;
    t.price = c;
    if (o > 0) t.open24 = o;
    if (h > 0) t.high24 = h;
    if (l > 0) t.low24 = l;
    if (q > 0) t.quoteVol24 = q;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (t.samples.isEmpty || now - t.samples.last.t >= 2000) {
      t.samples.add(Sample(now, c, t.quoteVol24));
      final cut = now - 900000;
      var k = 0;
      while (k < t.samples.length && t.samples[k].t < cut) {
        k++;
      }
      if (k > 0) t.samples.removeRange(0, k);
    }
    // Bougie 3m construite a partir des ticks : sert de declencheur a la strategie independante par jeton.
    final bs = now ~/ 180000 * 180000;
    if (t.b3Start == 0) {
      t.b3Start = bs;
      t.b3Open = c;
      t.b3Last = c;
      t.b3Partial = true;
    } else if (bs > t.b3Start) {
      if (!t.b3Partial && t.b3Open > 0 && tokenStratOn && s != 'BTCUSDT') {
        final ret = (t.b3Last / t.b3Open - 1) * 100;
        if (ret.abs() >= tokP.impulse) _onImpulse(t, ret > 0, now);
      }
      t.b3Open = t.b3Last > 0 ? t.b3Last : c;
      t.b3Start = bs;
      t.b3Partial = false;
      t.b3Last = c;
    } else {
      t.b3Last = c;
    }
    if (t.anchor <= 0) {
      t.anchor = c;
    } else {
      final d = (c / t.anchor - 1) * 100;
      if (d.abs() >= sens.step) {
        t.events.add(MoveEvent(now, d > 0));
        t.anchor = c;
      }
    }
  }

  double _moveSince(TokenData t, int now, int ms) {
    final cut = now - ms;
    for (final s in t.samples) {
      if (s.t >= cut) {
        if (now - s.t < ms * 0.5) return 0;
        return s.price > 0 ? (t.price / s.price - 1) * 100 : 0;
      }
    }
    return 0;
  }

  double _volRatio(TokenData t, int now) {
    final cut = now - 300000;
    for (final s in t.samples) {
      if (s.t >= cut) {
        final span = now - s.t;
        if (span < 150000) return 1;
        final delta = t.quoteVol24 - s.quoteVol;
        final expected = t.quoteVol24 / 86400000.0 * span;
        if (expected <= 0) return 1;
        return clampD(delta / expected, 0, 10);
      }
    }
    return 1;
  }

  void _recompute(TokenData t, int now) {
    t.events.removeWhere((e) => now - e.t > 600000);
    var up = 0;
    var down = 0;
    var flips = 0;
    bool? last;
    for (final e in t.events) {
      if (e.up) {
        up++;
      } else {
        down++;
      }
      if (last != null && last != e.up) flips++;
      last = e.up;
    }
    t.upEvents = up;
    t.downEvents = down;
    t.flips = flips;
    t.move1m = _moveSince(t, now, 60000);
    t.move5m = _moveSince(t, now, 300000);
    t.volRatio = _volRatio(t, now);

    final total = up + down;
    final dirEv = math.max(up, down);
    final continuity = total >= 2 ? dirEv / total : 0.0;
    final step = sens.step;
    final s1 = math.min(40.0, dirEv / sens.minEvents * 25);
    final s2 = math.min(25.0, t.move5m.abs() / (step * 4) * 25);
    final s3 = math.min(20.0, math.max(0.0, t.volRatio - 1) * 10);
    final s4 = continuity * 15;
    t.score = math.min(100.0, s1 + s2 + s3 + s4);

    if (up > down) {
      t.direction = 'up';
    } else if (down > up) {
      t.direction = 'down';
    } else {
      t.direction = t.move5m > 0 ? 'up' : (t.move5m < 0 ? 'down' : 'neutral');
    }
    final sp = t.move1m.abs() / step;
    t.speed = sp >= 3 ? 'explosive' : (sp >= 1.5 ? 'rapide' : (sp >= 0.5 ? 'normale' : 'lente'));
  }

  void _tick() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (tokens.isNotEmpty && now - math.max(_lastWsMs, _lastSwitchMs) > 15000) {
      _rotateWs(now);
    }
    if (now - _lastWsMs > 20000 && !_polling && now - _lastPollMs > 5000) {
      unawaited(_pollRest(_gen));
    }
    final all = tokens.values.where((t) => t.price > 0).toList()
      ..sort((a, b) => b.quoteVol24.compareTo(a.quoteVol24));
    final pool = favoritesOnly
        ? all.where((t) => favorites.contains(t.symbol)).toList()
        : all.take(topN).toList();
    _poolSyms = <String>{for (final t in pool) t.symbol};
    for (final t in pool) {
      _recompute(t, now);
      t.updateVolVar(volLive);
      t.updatePriceVar();
    }
    _computeSel(pool);
    _checkAlerts(pool, now);
    _sortPool(pool);
    ranking = pool;
    sim.onPrices();
    _recomputeBtcIdx();
    _recomputeXauIdx();
    notifyListeners();
  }

  void _checkAlerts(List<TokenData> pool, int now) {
    for (final t in pool) {
      if (t.dirEvents >= sens.minEvents &&
          t.score >= sens.alertScore &&
          now - t.lastAlertMs > 900000) {
        _fire(t, now);
      }
    }
  }

  void _fire(TokenData t, int now) {
    t.lastAlertMs = now;
    final up = t.direction == 'up';
    final title = up
        ? '🚀 ${t.base} se prepare a exploser ↑'
        : '⚠️ ${t.base} se prepare a chuter ↓';
    final against = (up && btcTrend == Trend.bear) || (!up && btcTrend == Trend.bull);
    final body = 'Score ${t.score.round()} · ${t.move5m.toStringAsFixed(2)}% en 5 min · '
        '${t.dirEvents} mouvements · ${t.price}${against ? ' · contre flux BTC' : ''}';
    alerts.insert(
      0,
      AlertItem(
        symbol: t.symbol,
        base: t.base,
        up: up,
        score: t.score,
        move5m: t.move5m,
        events: t.dirEvents,
        price: t.price,
        time: now,
        title: title,
        body: body,
      ),
    );
    if (alerts.length > 50) alerts.removeLast();
    if (autoTrade) {
      if (anyBarrierOn) {
        final btf = openBarrierTf(up);
        if (btf != null) {
          unawaited(_autoTrade(t, up, source: 'barrier$btf'));
        } else {
          sim.lastAutoMsg = '${t.base} : aucune barriere BTC ouverte dans ce sens';
        }
      } else {
        unawaited(_autoTrade(t, up));
      }
    }
  }

  void _sortPool(List<TokenData> pool) {
    int cmp(TokenData a, TokenData b) {
      switch (sortKey) {
        case SortKey.score:
          return b.score.compareTo(a.score);
        case SortKey.change:
          return b.change24.compareTo(a.change24);
        case SortKey.volume:
          return b.quoteVol24.compareTo(a.quoteVol24);
        case SortKey.volVar:
          return (b.volVar[1] ?? 0.0).compareTo(a.volVar[1] ?? 0.0);
        case SortKey.speed:
          return b.move1m.abs().compareTo(a.move1m.abs());
      }
    }

    pool.sort((a, b) {
      final c = cmp(a, b);
      return c != 0 ? c : b.quoteVol24.compareTo(a.quoteVol24);
    });
    for (var i = 0; i < pool.length; i++) {
      pool[i].rank = i + 1;
    }
  }

  // ---------------------------------------------------------------- actions

  void _resetDetector() {
    for (final t in tokens.values) {
      t.events.clear();
      t.anchor = 0;
      t.score = 0;
    }
  }

  void setMarket(Market m) {
    if (m == market) return;
    market = m;
    _save();
    unawaited(start());
  }

  void setSensitivity(Sensitivity s) {
    sens = s;
    _resetDetector();
    _save();
    notifyListeners();
  }

  void setTopN(int n) {
    topN = n;
    _save();
    unawaited(_loadKlines(_gen, false));
    notifyListeners();
  }

  void setSort(SortKey k) {
    sortKey = k;
    notifyListeners();
  }

  void setFavoritesOnly(bool v) {
    favoritesOnly = v;
    _save();
    notifyListeners();
  }

  void applyPreset(int i) {
    final p = kPresets[i];
    presetIndex = i;
    sens = p.sens;
    topN = p.topN;
    favoritesOnly = p.favOnly;
    _resetDetector();
    _save();
    unawaited(_loadKlines(_gen, false));
    notifyListeners();
  }

  void toggleFavorite(String symbol) {
    if (favorites.contains(symbol)) {
      favorites.remove(symbol);
    } else {
      favorites.add(symbol);
      unawaited(_loadKlines(_gen, false));
    }
    _save();
    notifyListeners();
  }

  void setNotif(bool v) {
    notifOn = v;
    if (v) NativeBridge.requestPermission();
    _save();
    notifyListeners();
  }

  void setKeepAlive(bool v) {
    keepAlive = v;
    if (v) {
      NativeBridge.requestPermission();
      NativeBridge.startService();
    } else {
      NativeBridge.stopService();
    }
    _save();
    notifyListeners();
  }

  void setAutoTrade(bool v) {
    autoTrade = v;
    _save();
    notifyListeners();
  }

  void setRisk(double v) {
    riskPct = v;
    _save();
    notifyListeners();
  }

  void resetSim() {
    sim.reset();
    notifyListeners();
  }

  void testNotification() {
    NativeBridge.notify('Crypto Radar', 'Test de notification : tout fonctionne ✅');
  }
}

class _Armed {
  _Armed(this.dir, this.expireMs);
  final int dir;
  final int expireMs;
  int lastCheck = 0;
}

class SelResult {
  SelResult(this.ok, this.why);
  final bool ok;
  final String why;
}

class _Sel {
  _Sel(this.thr, this.exc);
  factory _Sel.empty() => _Sel(double.infinity, <String>{});
  final double thr;
  final Set<String> exc;
}
