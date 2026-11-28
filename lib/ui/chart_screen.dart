import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../binance_service.dart';
import '../engine.dart';
import '../format.dart';
import '../indicators.dart';
import '../models.dart';
import '../simulator.dart';
import '../theme.dart';

const Color _kEntry = Color(0xFF4DA3FF);
const double _kAxisW = 84.0;

class _Level {
  _Level(this.label, this.price, this.color, {this.dashed = true});
  final String label;
  final double price;
  final Color color;
  final bool dashed;
}

class ChartScreen extends StatefulWidget {
  const ChartScreen({super.key, required this.trade});
  final PaperTrade trade;

  @override
  State<ChartScreen> createState() => _ChartScreenState();
}

class _ChartScreenState extends State<ChartScreen> {
  static const List<String> _ivs = <String>['1m', '5m', '15m', '1h', '4h'];
  String _iv = '15m';
  List<Candle> _c = <Candle>[];
  String? _err;
  bool _loading = true;
  Timer? _timer;

  // Zoom / deplacement
  double _visible = 60; // nombre de bougies visibles
  double _baseVisible = 60;
  double _offset = 0; // bougies de decalage vers le passe (0 = derniere bougie a droite)
  bool _fitLevels = false; // true : l'echelle inclut tous les niveaux (entree, SL, TP)

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 8), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final api = BinanceService(widget.trade.futures ? Market.futures : Market.spot);
      final k = await api.klines(widget.trade.symbol, _iv, 300);
      if (!mounted) return;
      setState(() {
        _c = k;
        _err = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '$e';
        _loading = false;
      });
    }
  }

  void _zoom(double factor) {
    setState(() {
      final n = math.max(10.0, _c.length.toDouble());
      _visible = clampD(_visible * factor, 10.0, n);
      _offset = clampD(_offset, 0.0, math.max(0.0, _c.length - 10.0));
    });
  }

  void _recenter() {
    setState(() {
      _offset = 0;
      _visible = 60;
    });
  }

  List<_Level> _levels(PaperTrade t) {
    final list = <_Level>[
      _Level('ENTREE', t.entry, _kEntry),
      _Level(t.tp1Hit ? 'SL (BE)' : 'SL', t.sl, kRed),
      _Level('TP1', t.tp1, kGreen),
      _Level('TP2', t.tp2, const Color(0xFF7CE0B0)),
    ];
    if ((t.slInit - t.sl).abs() > t.entry * 1e-9) {
      list.add(_Level('SL init', t.slInit, kRed.withOpacity(0.6)));
    }
    final ex = t.exit;
    if (ex != null) list.add(_Level('SORTIE', ex, Colors.white, dashed: false));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.trade;
    return Scaffold(
      appBar: AppBar(
        title: Text('${t.symbol} · ${t.long ? 'LONG' : 'SHORT'} x${t.leverage.toStringAsFixed(0)}'),
        actions: <Widget>[IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: ListenableBuilder(
        listenable: engine,
        builder: (BuildContext context, Widget? _) {
          final isOpen = t.status == 'open';
          final live = isOpen ? engine.tokens[t.symbol]?.price : null;
          final pnl = isOpen && live != null ? t.unrealized(live) + t.realized : t.realized;
          final col = pnl >= 0 ? kGreen : kRed;
          return Column(
            children: <Widget>[
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: <Widget>[
                    for (final iv in _ivs)
                      Padding(
                        padding: const EdgeInsets.only(right: 6, top: 6, bottom: 6),
                        child: ChoiceChip(
                          label: Text(iv, style: const TextStyle(fontSize: 12)),
                          selected: _iv == iv,
                          onSelected: (bool _) {
                            setState(() {
                              _iv = iv;
                              _offset = 0;
                            });
                            _load();
                          },
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: <Widget>[
                    Text(isOpen ? 'EN COURS' : 'CLOS', style: const TextStyle(color: kMuted, fontSize: 11)),
                    const Spacer(),
                    Text('${fmtUsd(pnl)} USDT', style: TextStyle(color: col, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              Expanded(
                child: _loading && _c.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : (_err != null && _c.isEmpty)
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Text('Graphique indisponible : $_err',
                                  textAlign: TextAlign.center, style: const TextStyle(color: kMuted)),
                            ),
                          )
                        : LayoutBuilder(
                            builder: (BuildContext context, BoxConstraints cons) {
                              final plotW = cons.maxWidth - 4 - _kAxisW;
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onScaleStart: (ScaleStartDetails d) => _baseVisible = _visible,
                                onScaleUpdate: (ScaleUpdateDetails d) {
                                  setState(() {
                                    final n = _c.length;
                                    if (d.pointerCount >= 2) {
                                      _visible = clampD(_baseVisible / d.scale, 10.0, math.max(10.0, n.toDouble()));
                                    }
                                    final per = plotW / _visible;
                                    if (per > 0) _offset += d.focalPointDelta.dx / per;
                                    _offset = clampD(_offset, 0.0, math.max(0.0, n - 10.0));
                                  });
                                },
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(4, 4, 0, 4),
                                  child: CustomPaint(
                                    size: Size.infinite,
                                    painter: _ChartPainter(
                                      _c,
                                      _levels(t),
                                      live,
                                      _visible,
                                      _offset,
                                      _fitLevels,
                                      _iv == '1h' || _iv == '4h',
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: <Widget>[
                    IconButton(
                      tooltip: 'Dezoomer',
                      icon: const Icon(Icons.zoom_out),
                      onPressed: () => _zoom(1.4),
                    ),
                    IconButton(
                      tooltip: 'Zoomer',
                      icon: const Icon(Icons.zoom_in),
                      onPressed: () => _zoom(1 / 1.4),
                    ),
                    IconButton(
                      tooltip: 'Recentrer',
                      icon: const Icon(Icons.center_focus_strong),
                      onPressed: _recenter,
                    ),
                    const Spacer(),
                    FilterChip(
                      label: const Text('Tous les niveaux', style: TextStyle(fontSize: 11)),
                      selected: _fitLevels,
                      onSelected: (bool v) => setState(() => _fitLevels = v),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 2,
                  children: const <Widget>[
                    _Legend('Entree', _kEntry),
                    _Legend('Stop loss', kRed),
                    _Legend('TP1 / TP2', kGreen),
                    _Legend('Prix actuel', kGold),
                    Text('Pincez pour zoomer · glissez pour deplacer', style: TextStyle(fontSize: 10, color: kMuted)),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(width: 14, height: 3, color: color),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 10, color: kMuted)),
      ],
    );
  }
}

class _Tag {
  _Tag(this.y, this.text, this.bg, this.fg);
  double y;
  final String text;
  final Color bg;
  final Color fg;
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.c, this.levels, this.live, this.visible, this.offset, this.fitLevels, this.longTime);
  final List<Candle> c;
  final List<_Level> levels;
  final double? live;
  final double visible;
  final double offset;
  final bool fitLevels;
  final bool longTime;

  TextPainter _tp(String s, Color color, double size, {FontWeight w = FontWeight.normal}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size, fontWeight: w)),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    return tp;
  }

  String _time(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final hm = '${two(d.hour)}:${two(d.minute)}';
    return longTime ? '${two(d.day)}/${two(d.month)} $hm' : hm;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (c.isEmpty) return;
    const topPad = 10.0;
    const botPad = 22.0;
    final plotW = size.width - _kAxisW;
    final plotH = size.height - topPad - botPad;
    if (plotW <= 10 || plotH <= 10) return;

    final n = c.length;
    final vis = math.max(10, math.min(n, visible.round()));
    final end = math.max(vis, n - offset.round());
    final start = end - vis;
    final lp = (end == n) ? live : null;

    double lo = double.infinity;
    double hi = -double.infinity;
    for (var i = start; i < end; i++) {
      lo = math.min(lo, c[i].l);
      hi = math.max(hi, c[i].h);
    }
    if (lp != null && lp > 0) {
      lo = math.min(lo, lp);
      hi = math.max(hi, lp);
    }
    if (fitLevels) {
      for (final l in levels) {
        if (l.price > 0) {
          lo = math.min(lo, l.price);
          hi = math.max(hi, l.price);
        }
      }
    }
    if (hi <= lo) hi = lo * 1.001 + 1e-9;
    final pad = (hi - lo) * 0.08;
    lo -= pad;
    hi += pad;
    double y(double p) => topPad + (hi - p) / (hi - lo) * plotH;

    // Grille + echelle des prix
    final grid = Paint()
      ..color = kSurface2
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final p = hi - (hi - lo) * i / 4;
      final yy = y(p);
      canvas.drawLine(Offset(0, yy), Offset(plotW, yy), grid);
      final t = _tp(fmtPrice(p), kMuted, 9);
      t.paint(canvas, Offset(plotW + 4, yy - t.height / 2));
    }

    // Echelle de temps
    for (var j = 0; j < 4; j++) {
      final idx = start + ((vis - 1) * j / 3).round();
      final x = (idx - start) * (plotW / vis) + (plotW / vis) / 2;
      final t = _tp(_time(c[idx].t), kMuted, 9);
      final tx = math.max(0.0, math.min(plotW - t.width, x - t.width / 2));
      t.paint(canvas, Offset(tx, size.height - botPad + 6));
      canvas.drawLine(Offset(x, topPad + plotH), Offset(x, topPad + plotH + 3), grid);
    }

    // Bougies (corps larges, meches epaisses)
    final step = plotW / vis;
    final bw = math.max(2.0, step * 0.78);
    final wickW = math.max(1.4, math.min(2.4, step * 0.18));
    for (var i = start; i < end; i++) {
      var k = c[i];
      if (i == n - 1 && lp != null && lp > 0) {
        k = Candle(k.t, k.o, math.max(k.h, lp), math.min(k.l, lp), lp, k.v, k.qv);
      }
      final up = k.c >= k.o;
      final col = up ? kGreen : kRed;
      final x = (i - start) * step + step / 2;
      canvas.drawLine(
        Offset(x, y(k.h)),
        Offset(x, y(k.l)),
        Paint()
          ..color = col
          ..strokeWidth = wickW,
      );
      final top = y(math.max(k.o, k.c));
      final bottom = y(math.min(k.o, k.c));
      final rect = Rect.fromLTRB(x - bw / 2, top, x + bw / 2, math.max(bottom, top + 2));
      canvas.drawRect(rect, Paint()..color = col);
      if (bw >= 5) {
        canvas.drawRect(
          rect,
          Paint()
            ..color = Colors.white.withOpacity(0.35)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.7,
        );
      }
    }

    // Lignes de niveau (entree, SL, TP...) + etiquettes de prix
    final tags = <_Tag>[];
    for (final l in levels) {
      if (l.price <= 0) continue;
      var yy = y(l.price);
      final above = yy < topPad;
      final below = yy > topPad + plotH;
      final outside = above || below;
      if (above) yy = topPad + 1;
      if (below) yy = topPad + plotH - 1;
      final paint = Paint()
        ..color = outside ? l.color.withOpacity(0.5) : l.color
        ..strokeWidth = 1.2;
      if (l.dashed || outside) {
        var x = 0.0;
        while (x < plotW) {
          canvas.drawLine(Offset(x, yy), Offset(math.min(x + 6, plotW), yy), paint);
          x += 10;
        }
      } else {
        canvas.drawLine(Offset(0, yy), Offset(plotW, yy), paint);
      }
      final lab = _tp(l.label, l.color, 9, w: FontWeight.bold);
      final ly = outside ? (above ? yy + 2 : yy - lab.height - 2) : yy - lab.height - 1;
      lab.paint(canvas, Offset(4, ly));
      final arrow = above ? '▲ ' : (below ? '▼ ' : '');
      tags.add(_Tag(yy, '$arrow${fmtPrice(l.price)}', l.color, Colors.black));
    }
    if (lp != null && lp > 0) {
      final yy = y(lp);
      canvas.drawLine(
        Offset(0, yy),
        Offset(plotW, yy),
        Paint()
          ..color = kGold
          ..strokeWidth = 1,
      );
      tags.add(_Tag(yy, fmtPrice(lp), kGold, Colors.black));
    }

    // Anti-chevauchement des etiquettes sur l'axe de droite
    tags.sort((a, b) => a.y.compareTo(b.y));
    for (var i = 1; i < tags.length; i++) {
      if (tags[i].y - tags[i - 1].y < 15) tags[i].y = tags[i - 1].y + 15;
    }
    for (final tg in tags) {
      final tp = _tp(tg.text, tg.fg, 9, w: FontWeight.bold);
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(plotW + 2, tg.y - 8, _kAxisW - 4, 16),
        const Radius.circular(3),
      );
      canvas.drawRRect(r, Paint()..color = tg.bg);
      tp.paint(canvas, Offset(plotW + 2 + (_kAxisW - 4 - tp.width) / 2, tg.y - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => true;
}
