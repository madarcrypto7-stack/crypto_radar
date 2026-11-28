import 'package:flutter/material.dart';
import '../engine.dart';
import '../models.dart';
import '../strategy3m.dart';
import '../theme.dart';

void showQuickPanel(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kSurface,
    constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.88),
    builder: (BuildContext ctx) => const _QuickPanel(),
  );
}

class _QuickPanel extends StatelessWidget {
  const _QuickPanel();

  static const Map<SortKey, String> _sorts = <SortKey, String>{
    SortKey.score: 'Score',
    SortKey.speed: 'Vitesse',
    SortKey.change: '% 24h',
    SortKey.volume: 'Volume',
    SortKey.volVar: 'Var. vol 1J',
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (BuildContext context, Widget? _) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(Icons.bolt, color: kGold),
                    const SizedBox(width: 6),
                    const Text('ACCES RAPIDE', style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 15)),
                    const Spacer(),
                    IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
                  ],
                ),
                const _Label('Marche'),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<Market>(
                    showSelectedIcon: false,
                    segments: const <ButtonSegment<Market>>[
                      ButtonSegment<Market>(value: Market.spot, label: Text('SPOT')),
                      ButtonSegment<Market>(value: Market.futures, label: Text('FUTURES')),
                    ],
                    selected: <Market>{engine.market},
                    onSelectionChanged: (Set<Market> s) => engine.setMarket(s.first),
                  ),
                ),
                const _Label('Flux BTC'),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<BtcMode>(
                    showSelectedIcon: false,
                    segments: const <ButtonSegment<BtcMode>>[
                      ButtonSegment<BtcMode>(
                          value: BtcMode.short, label: Text('COURT TERME · EMA 1h', style: TextStyle(fontSize: 11))),
                      ButtonSegment<BtcMode>(
                          value: BtcMode.long, label: Text('LONG TERME · EMA 4h', style: TextStyle(fontSize: 11))),
                    ],
                    selected: <BtcMode>{engine.btcMode},
                    onSelectionChanged: (Set<BtcMode> v) => engine.setBtcMode(v.first),
                  ),
                ),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(engine.btcInfo, style: const TextStyle(fontSize: 10, color: kMuted)),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: engine.refreshBtcNow,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Recalculer', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                ),
                const _Label('Classement par'),
                Wrap(
                  spacing: 6,
                  children: <Widget>[
                    for (final e in _sorts.entries)
                      ChoiceChip(
                        label: Text(e.value, style: const TextStyle(fontSize: 12)),
                        selected: engine.sortKey == e.key,
                        onSelected: (bool _) => engine.setSort(e.key),
                      ),
                  ],
                ),
                const _Label('Bougies affichees'),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const <ButtonSegment<bool>>[
                      ButtonSegment<bool>(value: false, label: Text('VARIATION VOLUME', style: TextStyle(fontSize: 11))),
                      ButtonSegment<bool>(value: true, label: Text('VARIATION PRIX', style: TextStyle(fontSize: 11))),
                    ],
                    selected: <bool>{engine.showPrice},
                    onSelectionChanged: (Set<bool> v) => engine.setShowPrice(v.first),
                  ),
                ),
                const _Label('Jetons scannes'),
                Wrap(
                  spacing: 6,
                  children: <Widget>[
                    for (final n in const <int>[30, 50, 100, 150, 200])
                      ChoiceChip(
                        label: Text('Top $n', style: const TextStyle(fontSize: 12)),
                        selected: engine.topN == n,
                        onSelected: (bool _) => engine.setTopN(n),
                      ),
                  ],
                ),
                const _Label('Sensibilite du detecteur'),
                Wrap(
                  spacing: 6,
                  children: <Widget>[
                    for (final s in Sensitivity.values)
                      ChoiceChip(
                        label: Text(s.label, style: const TextStyle(fontSize: 12)),
                        selected: engine.sens == s,
                        onSelected: (bool _) => engine.setSensitivity(s),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Favoris uniquement'),
                  value: engine.favoritesOnly,
                  onChanged: engine.setFavoritesOnly,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Trading automatique (via les bureaux)'),
                  subtitle: Text(
                    engine.sim.lastAutoMsg.isEmpty ? 'Desactive par defaut' : 'Dernier : ${engine.sim.lastAutoMsg}',
                    style: const TextStyle(fontSize: 10),
                  ),
                  value: engine.autoTrade,
                  onChanged: engine.setAutoTrade,
                ),
                for (final tf in kBarrierTfs)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(engine.bcfg[tf]!.title),
                    subtitle: Text(_barrierStatus(tf), style: const TextStyle(fontSize: 10)),
                    value: engine.bcfg[tf]!.enabled,
                    onChanged: (bool v) => engine.setBarrierEnabled(tf, v),
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Filtre de classement des bureaux'),
                  subtitle: const Text('Long : monte depuis le bas · Short : excite en haut', style: TextStyle(fontSize: 10)),
                  value: engine.selFilterOn,
                  onChanged: engine.setSelFilter,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Strategie independante par jeton'),
                  value: engine.tokenStratOn,
                  onChanged: engine.setTokenStrat,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Notifications paper trading'),
                  value: engine.notifOn,
                  onChanged: engine.setNotif,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

String _barrierStatus(String tf) {
  if (!engine.bcfg[tf]!.enabled) return 'Desactivee';
  final b = engine.barriers[tf]!;
  if (b.state == 'open') return 'OUVERTE ${b.dir == 1 ? 'LONG' : 'SHORT'}';
  return b.state == 'armed' ? 'En attente du MACD' : 'Fermee';
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child: Text(text, style: const TextStyle(color: kMuted, fontSize: 12, fontWeight: FontWeight.w600)),
      );
}
