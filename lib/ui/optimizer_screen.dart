import 'package:flutter/material.dart';
import '../engine.dart';
import '../native_bridge.dart';
import '../optimizer.dart';
import '../strategy3m.dart';
import '../theme.dart';

class OptimizerScreen extends StatefulWidget {
  const OptimizerScreen({super.key, this.initialTf = '3m'});
  final String initialTf;

  @override
  State<OptimizerScreen> createState() => _OptimizerScreenState();
}

class _OptimizerScreenState extends State<OptimizerScreen> {
  late String _tf = widget.initialTf;
  late int _days = _daysFor(widget.initialTf).first;
  int _uni = 12;
  bool _run = false;
  String _prog = '';
  String? _err;
  List<OptReport>? _rep;

  static List<int> _daysFor(String tf) => tf == '3m' ? const <int>[7, 3, 14] : (tf == '15m' ? const <int>[30, 14, 60] : const <int>[60, 30, 120]);

  Future<void> _go() async {
    setState(() {
      _run = true;
      _err = null;
      _rep = null;
      _prog = 'Preparation...';
    });
    try {
      final list = engine.tokens.values
          .where((t) => t.symbol != 'BTCUSDT' && t.symbol != 'XAUUSDT' && t.price > 0)
          .toList()
        ..sort((a, b) => b.quoteVol24.compareTo(a.quoteVol24));
      final syms = list.take(_uni).map((t) => t.symbol).toList();
      final r = await runOptimization(
        market: engine.market,
        tf: _tf,
        days: _days,
        symbols: syms,
        barrierMin: engine.bcfg[_tf]!.durMin,
        topK: engine.topK,
        onProgress: (String s) {
          if (mounted) setState(() => _prog = s);
        },
      );
      if (!mounted) return;
      setState(() {
        _rep = r;
        _run = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '$e';
        _run = false;
      });
    }
  }

  String _st(Stats s) =>
      'n=${s.n} · gagnants ${s.winRate.toStringAsFixed(0)} % · E[R] ${s.exp >= 0 ? '+' : ''}${s.exp.toStringAsFixed(2)} · PF ${s.pf.toStringAsFixed(2)}';

  Future<void> _export() async {
    final r = _rep;
    if (r == null) return;
    final rows = <String>[
      'strategie,rang,impulsion_pct,fenetre,macd,sl_atr,tp_r,tenue_bougies,train_n,train_win_pct,train_E_R,train_PF,test_n,test_win_pct,test_E_R,test_PF,robuste',
    ];
    for (final rep in r) {
      for (var i = 0; i < rep.rows.length; i++) {
        final x = rep.rows[i];
        rows.add([
          '${rep.barrier ? 'barriere_btc' : 'jeton_independant'}_${rep.tf}',
          i + 1,
          x.p.impulse,
          x.p.win,
          '${x.p.fast}/${x.p.slow}/${x.p.sig}',
          x.p.slAtr,
          x.p.tpR,
          x.p.hold,
          x.train.n,
          x.train.winRate.toStringAsFixed(1),
          x.train.exp.toStringAsFixed(3),
          x.train.pf.toStringAsFixed(2),
          x.test.n,
          x.test.winRate.toStringAsFixed(1),
          x.test.exp.toStringAsFixed(3),
          x.test.pf.toStringAsFixed(2),
          x.robust ? 'oui' : 'non',
        ].join(','));
      }
    }
    final d = DateTime.now();
    final name = 'crypto_radar_optimisation_${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}_${d.hour.toString().padLeft(2, '0')}${d.minute.toString().padLeft(2, '0')}.csv';
    final path = await NativeBridge.saveFile(name, 'text/csv', '\uFEFF${rows.join('\n')}');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(path == null ? 'Echec de l enregistrement' : 'Resultats enregistres : $path')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rep = _rep;
    return Scaffold(
      appBar: AppBar(
        title: const Text('BACKTEST D OPTIMISATION'),
        actions: <Widget>[
          if (rep != null) IconButton(icon: const Icon(Icons.download), onPressed: _export),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          const Text(
            'Boucle fermee : bougie +x % et croisement MACD haussier (dans n importe quel ordre) = LONG, puis -x % et croisement baissier = SHORT, et ainsi de suite. '
            'En 3m, deux variantes sont optimisees : la barriere BTC (puis les jetons les plus actifs) et la strategie independante par jeton. '
            'En 15m et 1h (trades de longue duree), la barriere BTC est optimisee. '
            'Grille de parametres (seuil, fenetre, MACD, stop, objectif, duree de tenue) sur l historique recent, validation hors echantillon (70 % apprentissage / 30 % test).',
            style: TextStyle(fontSize: 12, color: kMuted, height: 1.4),
          ),
          const SizedBox(height: 10),
          const Text('Echelle de la barriere', style: TextStyle(fontSize: 12, color: kMuted)),
          Wrap(
            spacing: 6,
            children: <Widget>[
              for (final t in kBarrierTfs)
                ChoiceChip(
                  label: Text(t),
                  selected: _tf == t,
                  onSelected: _run
                      ? null
                      : (bool _) => setState(() {
                            _tf = t;
                            _days = _daysFor(t).first;
                          }),
                ),
            ],
          ),
          const SizedBox(height: 6),
          const Text('Periode', style: TextStyle(fontSize: 12, color: kMuted)),
          Wrap(
            spacing: 6,
            children: <Widget>[
              for (final d in _daysFor(_tf))
                ChoiceChip(
                  label: Text('$d jours'),
                  selected: _days == d,
                  onSelected: _run ? null : (bool _) => setState(() => _days = d),
                ),
            ],
          ),
          const SizedBox(height: 6),
          const Text('Jetons testes (les plus echanges)', style: TextStyle(fontSize: 12, color: kMuted)),
          Wrap(
            spacing: 6,
            children: <Widget>[
              for (final u in const <int>[8, 12, 20])
                ChoiceChip(
                  label: Text('$u'),
                  selected: _uni == u,
                  onSelected: _run ? null : (bool _) => setState(() => _uni = u),
                ),
            ],
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _run ? null : _go,
            icon: const Icon(Icons.science),
            label: Text(_run ? 'Calcul en cours...' : 'Lancer l optimisation'),
          ),
          if (_run)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: <Widget>[
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: kGreen)),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_prog, style: const TextStyle(fontSize: 12))),
                ],
              ),
            ),
          if (_err != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('Erreur : $_err', style: const TextStyle(color: kRed)),
            ),
          if (rep != null)
            for (final r in rep) ...<Widget>[
              const SizedBox(height: 16),
              Text(r.name, style: const TextStyle(color: kGold, fontWeight: FontWeight.bold)),
              Text('${r.combos} combinaisons testees · meilleures par E[R] x racine(n) sur l apprentissage (n >= 25)',
                  style: const TextStyle(fontSize: 11, color: kMuted)),
              if (r.rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('Aucune combinaison avec assez de trades (>= 25). Essayez 14 jours ou plus de jetons.',
                      style: TextStyle(color: kMuted)),
                ),
              for (var i = 0; i < r.rows.length; i++)
                Card(
                  color: kSurface,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Text('#${i + 1}', style: const TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(width: 8),
                            if (r.rows[i].robust)
                              const Text('✔ robuste', style: TextStyle(color: kGreen, fontSize: 11, fontWeight: FontWeight.bold))
                            else
                              const Text('fragile', style: TextStyle(color: kRed, fontSize: 11)),
                            const Spacer(),
                            TextButton(
                              onPressed: () {
                                engine.applyOptimized(r.tf, r.barrier, r.rows[i].p);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Parametres appliques (SL/TP optimises actives)')),
                                );
                              },
                              child: const Text('APPLIQUER'),
                            ),
                          ],
                        ),
                        Text(r.rows[i].p.label, style: const TextStyle(fontSize: 11)),
                        const SizedBox(height: 4),
                        Text('Apprentissage : ${_st(r.rows[i].train)}', style: const TextStyle(fontSize: 11, color: kMuted)),
                        Text('Test hors echantillon : ${_st(r.rows[i].test)}',
                            style: TextStyle(fontSize: 11, color: r.rows[i].test.exp > 0 ? kGreen : kRed)),
                      ],
                    ),
                  ),
                ),
            ],
          const SizedBox(height: 16),
          const Text(
            'Limites : entrees au marche a la cloture de la bougie, frais inclus, stop prioritaire si stop et objectif sont touches '
            'dans la meme bougie, jetons choisis parmi les plus echanges aujourd hui (biais de survie), historique recent seulement. '
            'Une combinaison "robuste" doit rester positive hors echantillon, mais rien ne garantit qu elle le reste. '
            'Simulation uniquement, pas un conseil financier.',
            style: TextStyle(fontSize: 11, color: kMuted, height: 1.4),
          ),
        ],
      ),
    );
  }
}
