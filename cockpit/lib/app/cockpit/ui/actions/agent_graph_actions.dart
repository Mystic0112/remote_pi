import 'dart:async' show Timer;

import 'package:cockpit/app/cockpit/ui/actions/tab_actions.dart';
import 'package:cockpit/app/cockpit/ui/session/pane_item.dart';
import 'package:cockpit/app/cockpit/ui/session/terminal_session.dart';
import 'package:cockpit/app/cockpit/ui/states/pane_node.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/agent_graph_store.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/agent_message_delivery.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/cockpit_viewmodel.dart';
import 'package:cockpit/app/cockpit/ui/widgets/new_agent_dialog.dart';
import 'package:cockpit/app/cockpit/ui/widgets/realm_dialogs.dart';
import 'package:cockpit/app/core/domain/result.dart';
import 'package:cockpit/app/core/ui/widgets/app_menu.dart';
import 'package:cockpit/i18n/strings.g.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Rótulos manuais em uso (minúsculos). Globais de propósito: o `--to` do
/// `cockpit msg` resolve label entre TODAS as abas, não só do workspace.
Set<String> takenLabels(Iterable<PaneItem> tabs, {String? except}) => {
  for (final t in tabs)
    if (t.id != except)
      if (t.manualLabel case final l?) l.toLowerCase(),
};

/// [base], ou `base 2`, `base 3`… — o primeiro livre em [taken] (minúsculos).
String defaultAgentName(String base, Set<String> taken) {
  if (!taken.contains(base.toLowerCase())) return base;
  for (var n = 2; ; n++) {
    final name = '$base $n';
    if (!taken.contains(name.toLowerCase())) return name;
  }
}

/// Terminal novo **ao lado** do grafo: outra pane se houver, senão split à
/// direita (o canvas segue visível). Devolve o id da aba criada.
String? launchAgentBeside(
  CockpitViewModel vm,
  String workspaceId,
  String graphTabId, {
  required String cwd,
  String? command,
  String? label,
}) {
  final tree = vm.tree(workspaceId);
  final mine = vm.leafOfTab(workspaceId, graphTabId);
  final other = tree == null
      ? null
      : leaves(tree).map((l) => l.id).where((id) => id != mine).firstOrNull;
  final res = vm.newTerminalTab(
    cwd: cwd,
    title: label,
    startupCommand: command,
    inPane: other ?? mine,
    splitDir: other == null ? SplitDir.vertical : null,
  );
  return res is Success<String, String> ? res.value : null;
}

/// Agentes do workspace — os nós do canvas: abas com harness detectado.
List<PaneItem> workspaceAgents(CockpitViewModel vm, String ws) =>
    workspaceAgentNodes(ws, vm.allSessions);

bool _alive(CockpitViewModel vm, PaneItem s) => identical(vm.session(s.id), s);

List<PaneItem> _peers(CockpitViewModel vm, String ws, PaneItem s) => [
  ...vm.agentGraph.peersOf(ws, s.id).map(vm.session).nonNulls,
];

/// Folga entre o harness ser detectado e a primeira mensagem: a TUI ainda
/// está desenhando quando o processo aparece.
// ponytail: espera fixa; troque por "primeiro prompt desenhado" se perder input.
const Duration kAgentBootSettle = Duration(seconds: 2);

/// Roda [run] uma vez, quando [s] tiver harness detectado e estiver ocioso.
void whenAgentReady(TerminalSession s, VoidCallback run) {
  void check() {
    if (s.activeHarness == null || s.status != TerminalStatus.idle) return;
    s.removeListener(check);
    Timer(kAgentBootSettle, run);
  }

  s.addListener(check);
  check();
}

/// Cria o agente do dialog "New agent": aba com label/cwd/comando, posição,
/// cor, monitor e links (maestro liga a todos; os outros, ao maestro atual).
/// Role, tarefa e apresentações vão quando o harness subir e ficar ocioso.
String? createAgent(
  CockpitViewModel vm,
  String ws,
  String graphTabId,
  NewAgentDraft d, {
  Offset? at,
}) {
  final id = launchAgentBeside(
    vm,
    ws,
    graphTabId,
    cwd: d.cwd,
    command: d.command.isEmpty ? null : d.command,
    label: d.label.isEmpty ? null : d.label,
  );
  final s = id == null ? null : vm.session(id);
  if (s is! TerminalSession) return null;
  if (!d.monitor) vm.agentGraph.setMonitored(ws, s.id, false);
  final linked = _attach(vm, ws, s, d, at: at);
  if (d.role.isEmpty && d.task.isEmpty && linked.isEmpty) return s.id;
  whenAgentReady(s, () {
    if (_alive(vm, s)) _greet(vm, ws, s, d, linked);
  });
  return s.id;
}

/// Posição, cor e links do nó novo [s] (maestro liga a todos; os outros, ao
/// maestro atual). Devolve os ligados agora.
List<PaneItem> _attach(
  CockpitViewModel vm,
  String ws,
  PaneItem s,
  NewAgentDraft d, {
  Offset? at,
}) {
  final g = vm.agentGraph;
  if (at != null) g.setPosition(ws, s.id, at);
  if (d.color case final c?) g.setColor(ws, s.id, c);
  if (d.maestro) {
    final ids = g.setMaestro(
      ws,
      s.id,
      workspaceAgents(vm, ws).map((a) => a.id),
    );
    return [...ids.map(vm.session).nonNulls];
  }
  final maestro = vm.session(g.maestroOf(ws) ?? '');
  return [
    if (maestro != null &&
        maestro.id != s.id &&
        g.addLink(ws, s.id, maestro.id))
      maestro,
  ];
}

/// Primeiras mensagens do nó novo [s]: role, tarefa e a apresentação (lista
/// de pares, se maestro); e [s] apresentado a cada um de [linked].
void _greet(
  CockpitViewModel vm,
  String ws,
  PaneItem s,
  NewAgentDraft d,
  List<PaneItem> linked,
) {
  deliverQueued(
    log: vm.agentMessages,
    target: s,
    targetAlive: () => _alive(vm, s),
    items: [
      if (d.role.isNotEmpty) (s, d.role),
      if (d.task.isNotEmpty) (s, d.task),
      if (d.maestro)
        (s, maestroIntroText(_peers(vm, ws, s)))
      else
        for (final p in linked) (p, linkIntroText(p)),
    ],
  );
  for (final p in linked) {
    _introduce(vm, p, s);
  }
}

/// [self] recebe a apresentação de [peer] (link novo).
void _introduce(CockpitViewModel vm, PaneItem self, PaneItem peer) =>
    deliverQueued(
      log: vm.agentMessages,
      target: self,
      targetAlive: () => _alive(vm, self),
      items: [(peer, linkIntroText(peer))],
    );

/// Promove [s] (agente já no canvas) a maestro: liga a todos, apresenta-o aos
/// recém-ligados e manda a ele a lista completa.
void makeMaestro(CockpitViewModel vm, String ws, PaneItem s) {
  final g = vm.agentGraph;
  final added = g.setMaestro(
    ws,
    s.id,
    workspaceAgents(vm, ws).map((a) => a.id),
  );
  for (final p in added.map(vm.session).nonNulls) {
    _introduce(vm, p, s);
  }
  deliverQueued(
    log: vm.agentMessages,
    target: s,
    targetAlive: () => _alive(vm, s),
    items: [(s, maestroIntroText(_peers(vm, ws, s)))],
  );
}

/// Nós que o canvas acabou de ver ([ids]) se ligam ao maestro atual.
void linkToMaestro(CockpitViewModel vm, String ws, Iterable<String> ids) {
  final m = vm.session(vm.agentGraph.maestroOf(ws) ?? '');
  if (m == null) return;
  final fresh = [
    for (final s in ids.map(vm.session).nonNulls)
      if (s.id != m.id && vm.agentGraph.addLink(ws, s.id, m.id)) s,
  ];
  if (fresh.isEmpty) return;
  for (final s in fresh) {
    _introduce(vm, s, m);
  }
  deliverQueued(
    log: vm.agentMessages,
    target: m,
    targetAlive: () => _alive(vm, m),
    items: [for (final s in fresh) (s, linkIntroText(s))],
  );
}

/// Liga [a]–[b] no grafo; link novo apresenta um ao outro pelo caminho do
/// `cockpit msg`.
void connectAgents(
  CockpitViewModel vm,
  String workspaceId,
  PaneItem a,
  PaneItem b,
) {
  if (!vm.agentGraph.addLink(workspaceId, a.id, b.id)) return;
  sendLinkIntros(
    log: vm.agentMessages,
    a: a,
    b: b,
    alive: (s) => _alive(vm, s),
  );
}

/// Foca a aba [tabId] do workspace selecionado.
void focusAgentTab(CockpitViewModel vm, String workspaceId, String tabId) {
  final leaf = vm.leafOfTab(workspaceId, tabId);
  if (leaf != null) vm.selectTab(leaf, tabId);
}

/// Clique direito num nó: focar, renomear, maestro, fechar a aba.
Future<void> showAgentNodeMenu(
  BuildContext context,
  CockpitViewModel vm,
  String ws,
  PaneItem s,
  Offset globalPosition,
) async {
  final tr = context.t.cockpit.agentGraph;
  final isMaestro = vm.agentGraph.maestroOf(ws) == s.id;
  final pick = await showAppMenu<String>(
    context,
    globalPosition: globalPosition,
    items: [
      AppMenuItem(value: 'focus', label: tr.focus, icon: Icons.open_in_new),
      AppMenuItem(value: 'rename', label: tr.rename, icon: Icons.edit_outlined),
      AppMenuItem(
        value: 'maestro',
        label: isMaestro ? tr.removeMaestro : tr.makeMaestro,
        icon: Icons.workspace_premium_outlined,
      ),
      const AppMenuItem.divider(),
      AppMenuItem(
        value: 'close',
        label: tr.closeTab,
        icon: Icons.close,
        danger: true,
      ),
    ],
  );
  if (!context.mounted) return;
  switch (pick) {
    case 'focus':
      focusAgentTab(vm, ws, s.id);
    case 'rename':
      final name = await showRealmNameDialog(
        context,
        title: tr.renameTitle,
        confirmLabel: tr.rename,
        takenNames: takenLabels(vm.allSessions, except: s.id),
        initial: s.manualLabel ?? s.displayTitle,
        placeholder: tr.name,
        duplicateMessage: tr.nameTaken,
      );
      if (name == null || !_alive(vm, s)) return;
      vm.setPaneLabel(s.id, name);
    case 'maestro':
      isMaestro ? vm.agentGraph.clearMaestro(ws) : makeMaestro(vm, ws, s);
    case 'close':
      final leaf = vm.leafOfTab(ws, s.id);
      if (leaf != null) {
        await requestCloseTab(context, s, () => vm.closeTab(leaf, s.id));
      }
  }
}
