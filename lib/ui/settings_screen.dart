import 'package:flutter/material.dart';
import '../engine.dart';
import '../format.dart';
import '../icon_store.dart';
import '../strategy3m.dart';
import 'optimizer_screen.dart';
import '../models.dart';
import '../theme.dart';
import 'widgets.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (BuildContext context, Widget? _) {
        return Scaffold(
          appBar: AppBar(title: const Text('REGLAGES')),
          body: ListView(
            padding: const EdgeInsets.all(12),
            children: <Widget>[
              const _H('Notifications'),
              SwitchListTile(
                title: const Text('Notifications paper trading'),
                subtitle: const Text('Une notification a l ouverture et a la cloture de chaque paper trade (pas pour le scan)'),
                value: engine.notifOn,
                onChanged: engine.setNotif,
              ),
              ListTile(
                title: const Text('Tester la notification'),
                trailing: const Icon(Icons.notifications),
                onTap: engine.testNotification,
              ),
              SwitchListTile(
                title: const Text('Garder le radar actif en arriere-plan'),
                subtitle: const Text('Service au premier plan (notification permanente). Consomme plus de batterie.'),
                value: engine.keepAlive,
                onChanged: engine.setKeepAlive,
              ),
              const _H('Sensibilite du detecteur'),
              Wrap(
                spacing: 6,
                children: <Widget>[
                  for (final s in Sensitivity.values)
                    ChoiceChip(
                      label: Text(s.label),
                      selected: engine.sens == s,
                      onSelected: (bool _) => engine.setSensitivity(s),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Pas de mouvement : ${engine.sens.step}% · mouvements requis : ${engine.sens.minEvents} · '
                  'score d alerte : ${engine.sens.alertScore.round()}',
                  style: const TextStyle(fontSize: 11, color: kMuted),
                ),
              ),
              const _H('Flux BTC'),
              SegmentedButton<BtcMode>(
                showSelectedIcon: false,
                segments: const <ButtonSegment<BtcMode>>[
                  ButtonSegment<BtcMode>(value: BtcMode.short, label: Text('COURT TERME · EMA 1h', style: TextStyle(fontSize: 11))),
                  ButtonSegment<BtcMode>(value: BtcMode.long, label: Text('LONG TERME · EMA 4h', style: TextStyle(fontSize: 11))),
                ],
                selected: <BtcMode>{engine.btcMode},
                onSelectionChanged: (Set<BtcMode> v) => engine.setBtcMode(v.first),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  'Haussier si EMA7 > EMA25 et prix > EMA25 sur le delai choisi (baissier dans le cas inverse). '
                  'Le flux BTC est un contexte : les bureaux decident avec la tendance propre du jeton. '
                  'Contre le flux BTC, un trade n est permis que si le jeton est au moins 2 % plus fort (long) ou plus faible (short) que BTC sur 24 h, avec un risque reduit de moitie.',
                  style: TextStyle(fontSize: 11, color: kMuted, height: 1.4),
                ),
              ),
              const _H('Variation de volume'),
              SwitchListTile(
                title: const Text('Inclure aujourd hui (jour UTC en cours)'),
                subtitle: const Text(
                  'Active : 1J = aujourd hui (volume du jour UTC, mis a jour chaque minute). Desactive : jours clos uniquement (1J = hier).',
                  style: TextStyle(fontSize: 11),
                ),
                value: engine.volLive,
                onChanged: engine.setVolLive,
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text(
                  'Variation % = (V recent - V precedent) / V precedent x 100\n'
                  'V recent = somme des volumes des N derniers jours ; V precedent = somme des N jours d avant (N+1 a 2N). '
                  'N = 1, 7, 30, 90, 180. n/d si le jeton a moins de 2N jours d historique.',
                  style: TextStyle(fontSize: 11, color: kMuted, height: 1.4),
                ),
              ),
              const _H('Flux BTC : barrieres 3m · 15m · 1h'),
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text(
                  'Boucle fermee : +x % puis MACD (DIF au-dessus de DEA) ou MACD puis +x % ouvre la barriere LONG ; '
                  'elle surveille aussitot l inverse : -x % puis MACD (DIF sous DEA) ou MACD puis -x % ouvre la barriere SHORT, et ainsi de suite. '
                  'Elle s ouvre aux jetons les plus actifs de la meme tendance, et les bureaux preparent la selection comme d habitude. '
                  '3m court terme, 15m et 1h pour des trades de longue duree.',
                  style: TextStyle(fontSize: 11, color: kMuted, height: 1.4),
                ),
              ),
              for (final tf in kBarrierTfs) _BarrierCard(tf: tf),
              _SliderRow(
                label: 'Jetons les plus actifs autorises (top K)',
                valueText: '${engine.topK}',
                value: engine.topK.toDouble(),
                min: 3,
                max: 20,
                divisions: 17,
                onChanged: (double v) => engine.setTopK(v.round()),
              ),
              const _H('Selection de classement des bureaux'),
              SwitchListTile(
                title: const Text('Filtre de classement'),
                subtitle: const Text(
                  'LONG : on n execute pas les jetons deja en haut (excites, ils se preparent a la baisse) mais ceux qui montent depuis le bas, en filtrant les moins actifs vers le haut. '
                  'SHORT : on surveille les jetons en haut, deja excites, en filtrant les moins actifs vers le bas. '
                  'Les jetons les plus actifs dans le sens du trade sont toujours retenus.',
                  style: TextStyle(fontSize: 11),
                ),
                value: engine.selFilterOn,
                onChanged: engine.setSelFilter,
              ),
              _SliderRow(
                label: 'Jetons exceptionnels (les plus actifs dans le sens)',
                valueText: '${engine.selE}',
                value: engine.selE.toDouble(),
                min: 0,
                max: 10,
                divisions: 10,
                onChanged: (double v) => engine.setSelE(v.round()),
              ),
              const _H('Strategie independante par jeton (3m)'),
              SwitchListTile(
                title: const Text('Declencheur par jeton'),
                subtitle: const Text(
                  'Meme procedure appliquee au jeton lui-meme, sans attendre la barriere BTC.',
                  style: TextStyle(fontSize: 11),
                ),
                value: engine.tokenStratOn,
                onChanged: engine.setTokenStrat,
              ),
              _SliderRow(
                label: 'Seuil jeton (corps de la bougie 3m)',
                valueText: '${engine.tokP.impulse.toStringAsFixed(2)} %',
                value: engine.tokP.impulse,
                min: 0.2,
                max: 2.0,
                divisions: 36,
                onChanged: (double v) => engine.setTokP(engine.tokP.copyWith(impulse: (v * 20).round() / 20)),
              ),
              _SliderRow(
                label: 'Fenetre MACD jeton',
                valueText: '${engine.tokP.win}',
                value: engine.tokP.win.toDouble(),
                min: 2,
                max: 8,
                divisions: 6,
                onChanged: (double v) => engine.setTokP(engine.tokP.copyWith(win: v.round())),
              ),
              SwitchListTile(
                title: const Text('Utiliser le SL/TP optimises'),
                subtitle: Text(
                  'Jeton : ${engine.tokP.slAtr}xATR / ${engine.tokP.tpR}R · barrieres : voir chaque carte (regles via l optimisation)',
                  style: const TextStyle(fontSize: 11),
                ),
                value: engine.useStratExits,
                onChanged: engine.setUseStratExits,
              ),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (BuildContext _) => const OptimizerScreen()),
                ),
                icon: const Icon(Icons.tune),
                label: const Text('Backtest d optimisation'),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 6, bottom: 4),
                child: Text(
                  'Le trading automatique doit etre active pour que les barrieres et le declencheur ouvrent des paper trades. '
                  'Un mouvement de 0,65 % en 3 minutes est tres rare sur BTC : le backtest permet de trouver un seuil adapte.',
                  style: TextStyle(fontSize: 11, color: kMuted, height: 1.4),
                ),
              ),
              const _H('Simulateur'),
              Text('Risque par trade : ${engine.riskPct.toStringAsFixed(1)} % du capital virtuel'),
              Slider(
                value: engine.riskPct,
                min: 0.5,
                max: 3.0,
                divisions: 5,
                label: '${engine.riskPct.toStringAsFixed(1)} %',
                onChanged: engine.setRisk,
              ),
              _SliderRow(
                label: 'Delai avant rachat d un jeton apres sa sortie (SL, TP)',
                valueText: engine.reentryMin == 0 ? 'aucun' : fmtDur(engine.reentryMin),
                value: engine.reentryMin.toDouble(),
                min: 0,
                max: 240,
                divisions: 16,
                onChanged: (double v) => engine.setReentryMin(v.round()),
              ),
              Text('Exposition totale maximale : ${(engine.maxExposure * 100).round()} % du capital virtuel'),
              Slider(
                value: engine.maxExposure,
                min: 0.5,
                max: 2.0,
                divisions: 6,
                label: '${(engine.maxExposure * 100).round()} %',
                onChanged: engine.setMaxExposure,
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text(
                  'Trading automatique : l alerte lance les bureaux, le trade n est ouvert que s ils valident (stop ATR). '
                  'Maximum 3 ouvertures par 10 minutes, et pause de 30 minutes apres 3 pertes consecutives.',
                  style: TextStyle(fontSize: 11, color: kMuted, height: 1.4),
                ),
              ),
              const _H('Icones des jetons'),
              ListenableBuilder(
                listenable: IconStore.I,
                builder: (BuildContext c, Widget? _) {
                  final last = IconStore.I.lastCheck;
                  final d = DateTime.fromMillisecondsSinceEpoch(last);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('${IconStore.I.count} icones en base locale (${IconStore.px} px) · ${IconStore.I.missingCount} jetons sans icone'),
                      Text(
                        last == 0
                            ? 'Derniere verification : jamais'
                            : 'Derniere verification : ${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}',
                        style: const TextStyle(fontSize: 11, color: kMuted),
                      ),
                      ValueListenableBuilder<String>(
                        valueListenable: IconStore.I.progress,
                        builder: (BuildContext c2, String v, Widget? _) => v.isEmpty
                            ? const SizedBox.shrink()
                            : Text('Telechargement en cours : $v', style: const TextStyle(fontSize: 11, color: kGold)),
                      ),
                      const SizedBox(height: 6),
                      OutlinedButton.icon(
                        onPressed: () => IconStore.I.forceCheck(engine.tokens.values.map((t) => t.base).toList()),
                        icon: const Icon(Icons.sync, size: 16),
                        label: const Text('Verifier les mises a jour maintenant'),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(top: 6, bottom: 4),
                        child: Text(
                          'Les icones sont telechargees une seule fois dans la base locale, puis verifiees une fois par jour. '
                          'L affichage ne depend plus du reseau.',
                          style: TextStyle(fontSize: 11, color: kMuted, height: 1.4),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const _H('A savoir'),
              const Text(
                'Le score est un indicateur statistique de "preparation" (mouvements repetes, vitesse, flux de volume) : '
                'il ne predit pas une explosion de prix et ne garantit rien. Tout le trading est simule (paper). '
                'Ceci n est pas un conseil financier.',
                style: TextStyle(fontSize: 12, color: kMuted, height: 1.4),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _H extends StatelessWidget {
  const _H(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
        child: Text(text, style: const TextStyle(color: kGold, fontWeight: FontWeight.bold)),
      );
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });
  final String label;
  final String valueText;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
            Text(valueText, style: const TextStyle(color: kGold, fontWeight: FontWeight.bold)),
          ],
        ),
        Slider(
          value: clampD(value, min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _BarrierCard extends StatelessWidget {
  const _BarrierCard({required this.tf});
  final String tf;

  String _status(BarrierCfg c, BarrierState b) {
    if (!c.enabled) return 'Desactivee';
    if (b.state == 'open') {
      final left = ((b.expiresMs - DateTime.now().millisecondsSinceEpoch) / 60000).ceil();
      return 'OUVERTE ${b.dir == 1 ? 'LONG' : 'SHORT'} · reste ${fmtDur(left < 0 ? 0 : left)}\n${b.note}';
    }
    return '${b.state == 'armed' ? 'En attente' : 'Surveillance'} · ${b.note}';
  }

  double _round(double v, double step) => double.parse(((v / step).round() * step).toStringAsFixed(2));

  @override
  Widget build(BuildContext context) {
    final c = engine.bcfg[tf]!;
    final b = engine.barriers[tf]!;
    return Card(
      color: kSurface,
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(c.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        subtitle: MarkText(_status(c, b), style: const TextStyle(fontSize: 10, color: kMuted)),
        trailing: Switch(value: c.enabled, onChanged: (bool v) => engine.setBarrierEnabled(tf, v)),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _SliderRow(
            label: 'Seuil d impulsion (corps de la bougie $tf)',
            valueText: '${c.p.impulse.toStringAsFixed(2)} %',
            value: c.p.impulse,
            min: c.impMin,
            max: c.impMax,
            divisions: c.impDiv,
            onChanged: (double v) => engine.setBarrierP(tf, c.p.copyWith(impulse: _round(v, c.impStep))),
          ),
          _SliderRow(
            label: 'Fenetre de confirmation MACD (bougies apres l impulsion)',
            valueText: '${c.p.win}',
            value: c.p.win.toDouble(),
            min: 2,
            max: 8,
            divisions: 6,
            onChanged: (double v) => engine.setBarrierP(tf, c.p.copyWith(win: v.round())),
          ),
          _SliderRow(
            label: 'Duree d ouverture de la barriere',
            valueText: fmtDur(c.durMin),
            value: c.durMin.toDouble(),
            min: c.minDur.toDouble(),
            max: c.maxDur.toDouble(),
            divisions: c.durDiv,
            onChanged: (double v) => engine.setBarrierDur(tf, v.round()),
          ),
          _SliderRow(
            label: 'Stop loss (x ATR $tf)',
            valueText: c.p.slAtr.toStringAsFixed(2),
            value: c.p.slAtr,
            min: 0.5,
            max: 5.0,
            divisions: 18,
            onChanged: (double v) => engine.setBarrierP(tf, c.p.copyWith(slAtr: _round(v, 0.25))),
          ),
          _SliderRow(
            label: 'Objectif TP (x risque)',
            valueText: c.p.tpR.toStringAsFixed(2),
            value: c.p.tpR,
            min: 0.5,
            max: 5.0,
            divisions: 18,
            onChanged: (double v) => engine.setBarrierP(tf, c.p.copyWith(tpR: _round(v, 0.25))),
          ),
          Wrap(
            spacing: 6,
            children: <Widget>[
              ChoiceChip(
                label: const Text('MACD 12/26/9', style: TextStyle(fontSize: 11)),
                selected: c.p.fast == 12,
                onSelected: (bool _) => engine.setBarrierP(tf, c.p.copyWith(fast: 12, slow: 26, sig: 9)),
              ),
              ChoiceChip(
                label: const Text('MACD 6/13/5', style: TextStyle(fontSize: 11)),
                selected: c.p.fast == 6,
                onSelected: (bool _) => engine.setBarrierP(tf, c.p.copyWith(fast: 6, slow: 13, sig: 5)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (BuildContext _) => OptimizerScreen(initialTf: tf)),
            ),
            icon: const Icon(Icons.tune, size: 16),
            label: Text('Backtest de la barriere $tf'),
          ),
        ],
      ),
    );
  }
}
