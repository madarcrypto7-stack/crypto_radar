import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../btc_flux.dart';
import '../engine.dart';
import '../format.dart';
import '../models.dart';
import '../strategy3m.dart';
import '../theme.dart';
import 'widgets.dart';

/// Couleur du flux : rouge (baissier) -> jaune (neutre) -> vert (haussier).
Color fluxColor(double score) {
  final s = clampD(score, -100.0, 100.0);
  const amber = Color(0xFFFFC857);
  if (s >= 0) return Color.lerp(amber, kNeonGreen, s / 100)!;
  return Color.lerp(amber, kNeonRed, -s / 100)!;
}

String _sgn(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(0)}';

/// Tableau de bord dynamique du flux BTC : une jauge graduee par echelle de temps + indice composite.
class BtcFluxGauges extends StatelessWidget {
  const BtcFluxGauges({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (BuildContext context, Widget? _) {
        final ix = engine.btcIdx;
        final idx = ix?.index ?? 0.0;
        final col = fluxColor(idx);
        final dec = engine.btcTrend == Trend.bull ? 'HAUSSIER' : (engine.btcTrend == Trend.bear ? 'BAISSIER' : 'inconnu');
        final btc = engine.tokens['BTCUSDT'];
        return InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: ix == null ? null : () => _showDetail(context),
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(8, 6, 8, 2),
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
            decoration: BoxDecoration(
              color: col.withOpacity(0.10),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: col.withOpacity(0.55)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(Icons.currency_bitcoin, size: 18, color: kGold),
                    const SizedBox(width: 4),
                    const Text('FLUX BTC', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    const SizedBox(width: 8),
                    Text(_sgn(idx), style: TextStyle(color: col, fontWeight: FontWeight.w800, fontSize: 18)),
                    if (ix != null && engine.btcIdxDelta.abs() >= 1)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(
                          '${engine.btcIdxDelta >= 0 ? '▲' : '▼'} ${_sgn(engine.btcIdxDelta)} / 5 min',
                          style: TextStyle(color: fluxColor(engine.btcIdxDelta * 4), fontSize: 10),
                        ),
                      ),
                    const Spacer(),
                    if (btc != null)
                      Text('${fmtPrice(btc.price)}  ${fmtPct2(btc.change24)}',
                          style: const TextStyle(fontSize: 11, color: kMuted)),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: <Widget>[
                    for (final tf in kBtcTfs)
                      Expanded(child: _Gauge(tf: tf, score: ix?.byTf[tf]?.score ?? 0.0, valid: ix?.byTf[tf]?.valid ?? false)),
                  ],
                ),
                const SizedBox(height: 6),
                _AlignBars(btc: ix, xau: engine.xauIdx),
                const SizedBox(height: 4),
                Text(
                  ix == null
                      ? 'Chargement des echelles de temps...'
                      : '${ix.regime} · ${ix.bull} haussiere(s) · ${ix.bear} baissiere(s) · ${ix.neutral} neutre(s)',
                  style: TextStyle(fontSize: 10, color: col, fontWeight: FontWeight.w600),
                ),
                const _BarrierLine(),
                Text(
                  'Decision des bureaux : $dec (${engine.btcMode.tag}) · toucher pour le detail',
                  style: const TextStyle(fontSize: 9, color: kMuted),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showDetail(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface,
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
      builder: (BuildContext ctx) => const _DetailSheet(),
    );
  }
}

class _Gauge extends StatelessWidget {
  const _Gauge({required this.tf, required this.score, required this.valid});
  final String tf;
  final double score;
  final bool valid;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        TweenAnimationBuilder<double>(
          tween: Tween<double>(end: valid ? score : 0.0),
          duration: const Duration(milliseconds: 700),
          curve: Curves.easeOutCubic,
          builder: (BuildContext context, double v, Widget? _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  height: 28,
                  width: double.infinity,
                  child: CustomPaint(painter: _GaugePainter(v, valid)),
                ),
                Text(
                  valid ? _sgn(v) : '...',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: valid ? fluxColor(v) : kMuted,
                  ),
                ),
              ],
            );
          },
        ),
        Text(tf, style: const TextStyle(fontSize: 10, color: kMuted)),
      ],
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter(this.score, this.valid);
  final double score;
  final bool valid;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height - 3;
    final r = math.min(size.width / 2 - 2, size.height - 4);
    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);
    const n = 20;
    const sweep = math.pi / n;
    // Arc gradue : rouge (gauche) -> jaune -> vert (droite)
    for (var i = 0; i < n; i++) {
      final t = (i + 0.5) / n;
      final c = fluxColor((t * 2 - 1) * 100);
      canvas.drawArc(
        rect,
        math.pi + i * sweep,
        sweep + 0.02,
        false,
        Paint()
          ..color = valid ? c : kSurface2
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
    }
    // Graduations (5 reperes)
    final tick = Paint()
      ..color = Colors.white.withOpacity(0.45)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final a = math.pi + i * math.pi / 4;
      canvas.drawLine(
        Offset(cx + math.cos(a) * (r - 6), cy + math.sin(a) * (r - 6)),
        Offset(cx + math.cos(a) * (r - 3), cy + math.sin(a) * (r - 3)),
        tick,
      );
    }
    if (!valid) return;
    // Aiguille
    final a = math.pi + (clampD(score, -100.0, 100.0) + 100) / 200 * math.pi;
    final tip = Offset(cx + math.cos(a) * (r - 5), cy + math.sin(a) * (r - 5));
    canvas.drawLine(
      Offset(cx, cy),
      tip,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(Offset(cx, cy), 2.4, Paint()..color = fluxColor(score));
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) => old.score != score || old.valid != valid;
}

class _DetailSheet extends StatelessWidget {
  const _DetailSheet();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (BuildContext context, Widget? _) {
        final ix = engine.btcIdx;
        if (ix == null) return const SizedBox(height: 120, child: Center(child: Text('Pas encore de donnees')));
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Text('FLUX BTC · DETAIL', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
                  ],
                ),
                Text(
                  'Indice composite ${_sgn(ix.index)} · ${ix.regime}',
                  style: TextStyle(color: fluxColor(ix.index), fontWeight: FontWeight.bold),
                ),
                Text(
                  'Court terme (15m, 30m, 1h) : ${_sgn(ix.shortAvg)}   ·   Long terme (4h, 8h, 12h) : ${_sgn(ix.longAvg)}',
                  style: const TextStyle(fontSize: 11, color: kMuted),
                ),
                const SizedBox(height: 10),
                for (final tf in kBtcTfs) _Row(tf: tf, s: ix.byTf[tf]),
                const SizedBox(height: 12),
                const Text(
                  'Methode : chaque echelle recoit un score de -100 a +100 par combinaison de 5 facteurs normalises par la volatilite (ATR) : '
                  'ecart EMA7/EMA25 (30 %), prix vs EMA25 (20 %), histogramme MACD DIF-DEA (20 %), RSI (15 %), Supertrend (15 %). '
                  'L indice composite pondere davantage les echelles longues (4h 22 %, 8h 18 %, 2h 17 %, 12h 15 %, 1h 15 %, 30m 8 %, 15m 5 %). '
                  'Un rebond (ou une correction) est signale quand le court terme est au moins a 20 dans un sens et le long terme au moins a 20 dans l autre. '
                  'Ce tableau est un outil de lecture : les decisions des bureaux utilisent le mode EMA 1h ou 4h choisi dans l acces rapide.',
                  style: TextStyle(fontSize: 11, color: kMuted, height: 1.4),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.tf, required this.s});
  final String tf;
  final TfScore? s;

  String _p(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final v = s;
    if (v == null || !v.valid) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text('$tf · donnees indisponibles', style: const TextStyle(color: kMuted, fontSize: 12)),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(width: 36, child: Text(tf, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
          SizedBox(
            width: 46,
            child: Text(_sgn(v.score), style: TextStyle(color: fluxColor(v.score), fontWeight: FontWeight.w800)),
          ),
          Expanded(
            child: Text(
              'EMA ${_p(v.emaPart)} · prix ${_p(v.pricePart)} · MACD ${_p(v.macdPart)} · RSI ${v.rsi.toStringAsFixed(0)} · ST ${v.stUp ? '↑' : '↓'}',
              style: const TextStyle(fontSize: 11, color: kMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Deux fines barres gradues (BTC et or XAU) sur les memes echelles de temps, avec l'alignement global en %.
class _AlignBars extends StatelessWidget {
  const _AlignBars({required this.btc, required this.xau});
  final BtcFluxIndex? btc;
  final BtcFluxIndex? xau;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            const SizedBox(width: 30),
            Expanded(
              child: Row(
                children: <Widget>[
                  for (final tf in kBtcTfs)
                    Expanded(
                      child: Center(child: Text(tf, style: const TextStyle(fontSize: 8.5, color: kMuted))),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 48),
          ],
        ),
        const SizedBox(height: 2),
        _BarRow(label: 'BTC', ix: btc),
        const SizedBox(height: 4),
        _BarRow(label: 'XAU', ix: xau),
      ],
    );
  }
}

class _BarRow extends StatelessWidget {
  const _BarRow({required this.label, required this.ix});
  final String label;
  final BtcFluxIndex? ix;

  @override
  Widget build(BuildContext context) {
    final x = ix;
    final al = x == null ? null : fluxAlignment(x);
    final col = al == null ? kMuted : fluxColor(al.dir * al.pct);
    return Row(
      children: <Widget>[
        SizedBox(
          width: 30,
          child: Text(label, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: kMuted)),
        ),
        Expanded(
          child: SizedBox(
            height: 9,
            child: CustomPaint(
              size: Size.infinite,
              painter: _BarPainter(<double?>[
                for (final tf in kBtcTfs) (x?.byTf[tf]?.valid ?? false) ? x!.byTf[tf]!.score : null,
              ]),
            ),
          ),
        ),
        SizedBox(
          width: 48,
          child: Align(
            alignment: Alignment.centerRight,
            child: Text(
              al == null ? '--' : '${al.dir > 0 ? '▲' : '▼'}${al.pct.round()}%',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: col),
            ),
          ),
        ),
      ],
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.scores);
  final List<double?> scores;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(size.height / 2));
    canvas.drawRRect(rr, Paint()..color = kSurface2);
    final n = scores.length;
    final colors = <Color>[];
    final stops = <double>[];
    for (var i = 0; i < n; i++) {
      final s = scores[i];
      colors.add(s == null ? kSurface2 : fluxColor(s));
      stops.add((i + 0.5) / n);
    }
    colors.insert(0, colors.first);
    stops.insert(0, 0.0);
    colors.add(colors.last);
    stops.add(1.0);
    canvas.drawRRect(
      rr,
      Paint()..shader = LinearGradient(colors: colors, stops: stops).createShader(rect),
    );
    // Graduations entre les echelles
    final tick = Paint()
      ..color = kBg.withOpacity(0.75)
      ..strokeWidth = 1.2;
    for (var i = 1; i < n; i++) {
      final x = size.width * i / n;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), tick);
    }
  }

  @override
  bool shouldRepaint(covariant _BarPainter old) => true;
}

/// Etat de la barriere BTC 3m (impulsion + croisement MACD).
class _BarrierLine extends StatelessWidget {
  const _BarrierLine();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (BuildContext context, Widget? _) => _content(),
    );
  }

  Widget _content() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final lines = <Widget>[];
    for (final tf in kBarrierTfs) {
      if (!engine.bcfg[tf]!.enabled) continue;
      final b = engine.barriers[tf]!;
      if (b.state == 'open') {
        final left = ((b.expiresMs - now) / 60000).ceil();
        lines.add(Text(
          '🚧 $tf OUVERTE ${b.dir == 1 ? '↑ LONG' : '↓ SHORT'} · reste ${fmtDur(left < 0 ? 0 : left)} · ${engine.topK} jetons les plus actifs',
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: fluxColor(b.dir * 100.0)),
        ));
        lines.add(MarkText(b.note, style: const TextStyle(fontSize: 9, color: kMuted)));
      } else if (b.state == 'armed') {
        lines.add(MarkText(
          '🚧 $tf en attente · ${b.note}',
          style: const TextStyle(fontSize: 10, color: Color(0xFFFFC857)),
        ));
      } else {
        lines.add(MarkText(
          '🚧 $tf surveillance · ${b.note}',
          style: const TextStyle(fontSize: 9, color: kMuted),
        ));
      }
    }
    if (lines.isEmpty) {
      return const Text('Barrieres BTC (3m · 15m · 1h) : desactivees', style: TextStyle(fontSize: 9, color: kMuted));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines);
  }
}
