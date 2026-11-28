import 'dart:math' as math;

const String kBuild = 'v30';

double toD(dynamic x) => x is num ? x.toDouble() : (double.tryParse('$x') ?? 0.0);

double clampD(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

enum Market { spot, futures }

extension MarketX on Market {
  String get label => this == Market.spot ? 'SPOT' : 'FUTURES';
  double get fee => this == Market.spot ? 0.001 : 0.0004;
}

enum Sensitivity { low, medium, high, ultra }

extension SensitivityX on Sensitivity {
  String get label => switch (this) {
        Sensitivity.low => 'FAIBLE',
        Sensitivity.medium => 'MOYENNE',
        Sensitivity.high => 'HAUTE',
        Sensitivity.ultra => 'ULTRA',
      };

  /// Pas de mouvement (en %) : un "mouvement" est compte a chaque fois que le prix bouge de ce pas.
  double get step => switch (this) {
        Sensitivity.low => 0.30,
        Sensitivity.medium => 0.20,
        Sensitivity.high => 0.12,
        Sensitivity.ultra => 0.07,
      };

  /// Nombre minimal de mouvements dans le meme sens (fenetre 10 min).
  int get minEvents => switch (this) {
        Sensitivity.low => 5,
        Sensitivity.medium => 4,
        Sensitivity.high => 3,
        Sensitivity.ultra => 3,
      };

  /// Score minimal (0-100) pour declencher l'alerte.
  double get alertScore => switch (this) {
        Sensitivity.low => 75.0,
        Sensitivity.medium => 65.0,
        Sensitivity.high => 55.0,
        Sensitivity.ultra => 45.0,
      };
}

enum Trend { bull, bear, unknown }

/// Base de calcul du flux BTC : court terme (EMA 7/25 en 1h) ou long terme (EMA 7/25 en 4h).
enum BtcMode { short, long }

extension BtcModeX on BtcMode {
  String get label => this == BtcMode.short ? 'COURT TERME · EMA 1h' : 'LONG TERME · EMA 4h';
  String get tag => this == BtcMode.short ? 'EMA 1h' : 'EMA 4h';
  String get tf => this == BtcMode.short ? '1h' : '4h';
}

/// Un trade contre le flux BTC n'est permis que si le jeton montre sa propre force (ecart de performance 24h vs BTC, en %).
const double kRelStrength = 2.0;

enum SortKey { score, change, volume, volVar, speed }

class ScanPreset {
  const ScanPreset(this.name, this.desc, this.sens, this.topN, this.favOnly);
  final String name;
  final String desc;
  final Sensitivity sens;
  final int topN;
  final bool favOnly;
}

const List<ScanPreset> kPresets = [
  ScanPreset('Scalp ultra-rapide', 'Top 50 - detection maximale', Sensitivity.ultra, 50, false),
  ScanPreset('Equilibre', 'Top 100 - sensibilite moyenne', Sensitivity.medium, 100, false),
  ScanPreset('Swing calme', 'Top 200 - alertes rares et solides', Sensitivity.low, 200, false),
  ScanPreset('Ma watchlist', 'Jetons favoris (etoile) - haute sensibilite', Sensitivity.high, 100, true),
];

const List<int> kPeriods = [1, 7, 30, 90, 180];

String periodLabel(int p) => switch (p) {
      1 => '1J',
      7 => '1S',
      30 => '1M',
      90 => '90J',
      _ => '180J',
    };

class Sample {
  Sample(this.t, this.price, this.quoteVol);
  final int t;
  final double price;
  final double quoteVol;
}

class MoveEvent {
  MoveEvent(this.t, this.up);
  final int t;
  final bool up;
}

class TokenData {
  TokenData(this.symbol)
      : base = symbol.endsWith('USDT') ? symbol.substring(0, symbol.length - 4) : symbol;

  final String symbol;
  final String base;

  double price = 0;
  double prevPrice = 0;
  double open24 = 0;
  double high24 = 0;
  double low24 = 0;
  double quoteVol24 = 0;

  double get change24 => open24 > 0 ? (price / open24 - 1) * 100 : 0;
  double get rangePct => price > 0 ? (high24 - low24) / price * 100 : 0;

  /// Position du prix dans la plage 24 h : 0 = au plus bas, 1 = au plus haut.
  double get rangePos {
    if (high24 <= low24) return 0.5;
    final r = (price - low24) / (high24 - low24);
    return r < 0 ? 0.0 : (r > 1 ? 1.0 : r);
  }

  // Variation de volume par periode (jours) : % vs periode precedente.
  final Map<int, double> volVar = {};
  List<double> dailyQuoteVol = [];
  List<double> dailyClose = [];
  int dailyLastT = 0;
  double todayOpen = 0;
  final Map<int, double> priceVar = {};
  bool klinesLoaded = false;

  // Detecteur
  final List<Sample> samples = [];
  final List<MoveEvent> events = [];
  double anchor = 0;
  double move1m = 0;
  double move5m = 0;
  double volRatio = 1;
  int upEvents = 0;
  int downEvents = 0;
  int flips = 0;
  double score = 0;
  String direction = 'neutral';
  String speed = 'slow';
  int lastAlertMs = 0;

  // Bougie 3m construite a partir des ticks (strategie independante par jeton)
  int b3Start = 0;
  double b3Open = 0;
  double b3Last = 0;
  bool b3Partial = true;

  int rank = 0;

  int get dirEvents => math.max(upEvents, downEvents);

  /// Performance du prix sur N jours (comme l'onglet Aujourd'hui / 7 / 30 / 90 / 180 jours de Binance) :
  /// (prix actuel / cloture d'il y a N jours - 1) x 100 ; 1J = variation glissante 24 h.
  void updatePriceVar() {
    // 1J = Aujourd'hui : prix actuel vs ouverture de la bougie du jour (UTC)
    priceVar[1] = todayOpen > 0 && price > 0 ? (price / todayOpen - 1) * 100 : change24;
    final n = dailyClose.length;
    for (final p in kPeriods) {
      if (p == 1) continue;
      final idx = n - 1 - p;
      if (idx < 0 || price <= 0) {
        priceVar.remove(p);
        continue;
      }
      final base = dailyClose[idx];
      if (base > 0) {
        priceVar[p] = (price / base - 1) * 100;
      } else {
        priceVar.remove(p);
      }
    }
  }

  /// Variation (%) = (V_recent - V_precedent) / V_precedent x 100
  /// V_recent    = somme des volumes (USDT) des N derniers jours
  /// V_precedent = somme des volumes des N jours d'avant (de N+1 a 2N)
  /// Mode exact (live = false) : uniquement des jours clos (UTC).
  /// Mode jour en cours : la derniere fenetre se termine aujourd'hui (volume reel du jour UTC, rafraichi chaque minute).
  /// Donnees insuffisantes (moins de 2N jours) : pas de valeur (affiche n/d).
  void updateVolVar(bool live) {
    final raw = dailyQuoteVol;
    final n = live ? raw.length : raw.length - 1;
    if (n < 2) return;
    double at(int i) => raw[i];
    double sum(int from, int to) {
      double s = 0;
      for (var i = from; i < to; i++) {
        s += at(i);
      }
      return s;
    }

    for (final p in kPeriods) {
      if (n < 2 * p) {
        volVar.remove(p);
        continue;
      }
      final recent = sum(n - p, n);
      final prev = sum(n - 2 * p, n - p);
      if (prev > 0) {
        volVar[p] = (recent - prev) / prev * 100;
      } else {
        volVar.remove(p);
      }
    }
  }
}

class AlertItem {
  AlertItem({
    required this.symbol,
    required this.base,
    required this.up,
    required this.score,
    required this.move5m,
    required this.events,
    required this.price,
    required this.time,
    required this.title,
    required this.body,
  });
  final String symbol;
  final String base;
  final bool up;
  final double score;
  final double move5m;
  final int events;
  final double price;
  final int time;
  final String title;
  final String body;
}
