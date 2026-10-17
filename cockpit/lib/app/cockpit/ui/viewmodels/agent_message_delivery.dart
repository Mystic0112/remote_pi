import 'dart:async' show Timer;

import 'package:cockpit/app/cockpit/domain/entities/agent_message.dart';
import 'package:cockpit/app/cockpit/ui/session/pane_item.dart';
import 'package:cockpit/app/cockpit/ui/session/terminal_session.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/agent_message_log.dart';
import 'package:cockpit/app/core/domain/entities/harness.dart';

/// Pausa entre o texto e o Enter: TUIs (o claude entre elas) tratam um write
/// único com `\r` no fim como colagem, não como submit. Mesma folga do
/// `scripts/cockpit-dispatch.sh`.
const Duration kAgentMessageSubmitDelay = Duration(milliseconds: 400);

/// Caminho único de entrega entre agentes (`cockpit msg` e as apresentações
/// do grafo), assinado como [senderName] · [senderHarness]. Terminal: digita
/// `[from: …] <text>` em [target] e aperta Enter depois do delay; [paste] manda
/// como colagem (bracketed paste, se o TUI pediu): texto multilinha não
/// submete no meio. Registra [text] no [log] como [from] → [target].
void deliverAgentMessage({
  required AgentMessageLog log,
  required PaneItem from,
  required PaneItem target,
  required String senderName,
  required String? senderHarness,
  required String text,
  required bool Function() targetAlive,
  bool paste = false,
}) {
  if (target is! TerminalSession) return;
  final line = AgentMessage.formatLine(
    senderName: senderName,
    senderHarness: senderHarness,
    text: text,
  );
  paste ? target.terminal.paste(line) : target.insertText(line);
  Timer(kAgentMessageSubmitDelay, () {
    // A aba pode ter fechado na janela do delay: PTY morto não recebe.
    if (targetAlive()) target.insertText('\r');
  });
  log.record(
    fromTabId: from.id,
    fromWorkspaceId: from.projectId,
    toTabId: target.id,
    toWorkspaceId: target.projectId,
    text: text,
    signedBy: AgentMessage.signature(senderName, senderHarness),
  );
}

/// Harness detectado na aba no wire (`HarnessKind.name`: `pi`, `claudeCode`…),
/// `null` fora de agente: o `harness` de `list-tabs` e `peers`.
String? agentHarnessName(PaneItem p) =>
    p is TerminalSession ? p.activeHarness?.name : null;

/// Nome do harness da aba (assinatura das mensagens e apresentações).
String? agentKindLabel(PaneItem p) => switch (p) {
  TerminalSession(:final activeHarness?) =>
    HarnessCatalog.getSpec(activeHarness)?.label ?? activeHarness.name,
  _ => null,
};

/// Apresentação que um agente recebe ao ser ligado a [peer] no grafo. Texto
/// pro agente (inglês de propósito, como toda saída da CLI).
String linkIntroText(PaneItem peer) {
  final name = agentKindLabel(peer);
  final raw = peer.manualLabel ?? peer.id;
  // Label com espaço/parêntese quebraria o `--to` no shell: vai entre aspas.
  final address = RegExp(r'^[\w.:-]+$').hasMatch(raw) ? raw : '"$raw"';
  return 'You are now connected to ${peer.displayTitle}'
      '${name == null ? '' : ' ($name)'}. '
      'Talk to it with: cockpit msg --to $address "..."';
}

/// Apresentação que o maestro recebe: todos os [peers] e como coordená-los.
String maestroIntroText(Iterable<PaneItem> peers) {
  final list = [
    for (final p in peers)
      switch (agentKindLabel(p)) {
        final kind? => '${p.manualLabel ?? p.id} ($kind)',
        null => p.manualLabel ?? p.id,
      },
  ];
  return 'You are the maestro of this workspace: you are connected to every '
      'agent on the canvas and coordinate them. Agents: '
      '${list.isEmpty ? '(none yet)' : list.join(', ')}. '
      'Message one with: cockpit msg --to <label> "..."; list them anytime '
      'with: cockpit peers';
}

/// Intervalo entre mensagens seguidas pro MESMO alvo: a anterior precisa
/// receber o Enter ([kAgentMessageSubmitDelay]) antes da próxima ser digitada.
const Duration kAgentMessageQueueGap = Duration(milliseconds: 1200);

/// Entrega [items] (`(from, text)`) em ordem pra [target], como
/// `[from: cockpit] <text>`, espaçadas por [kAgentMessageQueueGap].
// ponytail: espaçamento fixo, sem fila por alvo — duas rajadas pro mesmo alvo
// ao mesmo tempo ainda podem se misturar; fila real se isso aparecer.
void deliverQueued({
  required AgentMessageLog log,
  required PaneItem target,
  required List<(PaneItem, String)> items,
  required bool Function() targetAlive,
}) {
  for (final (i, (from, text)) in items.indexed) {
    Timer(kAgentMessageQueueGap * i, () {
      if (!targetAlive()) return;
      deliverAgentMessage(
        log: log,
        from: from,
        target: target,
        senderName: 'cockpit',
        senderHarness: null,
        text: text,
        targetAlive: targetAlive,
        paste: true,
      );
    });
  }
}

/// Manda a apresentação pros dois lados de um link novo [a]–[b]. Cada uma é
/// registrada como vinda do par apresentado (o cabo pulsa na criação).
void sendLinkIntros({
  required AgentMessageLog log,
  required PaneItem a,
  required PaneItem b,
  required bool Function(PaneItem) alive,
}) {
  for (final (self, peer) in [(a, b), (b, a)]) {
    final text = linkIntroText(peer);
    deliverAgentMessage(
      log: log,
      from: peer,
      target: self,
      senderName: 'cockpit',
      senderHarness: null,
      text: text,
      targetAlive: () => alive(self),
    );
  }
}
