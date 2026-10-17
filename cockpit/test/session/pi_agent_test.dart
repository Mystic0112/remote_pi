import 'dart:async';
import 'dart:convert';

import 'package:cockpit/app/cockpit/domain/contracts/terminal_gateway.dart';
import 'package:cockpit/app/cockpit/domain/contracts/terminal_status_server.dart';
import 'package:cockpit/app/cockpit/domain/services/terminal_harness_monitor.dart';
import 'package:cockpit/app/cockpit/ui/session/terminal_session.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/agent_graph_store.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/agent_message_delivery.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/agent_message_log.dart';
import 'package:cockpit/app/core/domain/entities/harness.dart';
import 'package:cockpit/app/core/domain/entities/terminal_profile.dart';
import 'package:cockpit/app/core/utils/spawn_directory.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pi é o alvo principal do projeto: este arquivo cobre a aba de Pi de ponta a
/// ponta (detecção → `list-tabs`/`peers`, nó do grafo, `cockpit msg`, status
/// de turno pelo hook da extensão e pela heurística de saída).

/// PTY falso que guarda o que foi escrito no stdin do shell.
class _PtyGateway implements TerminalGateway {
  final writes = <String>[];
  final out = StreamController<List<int>>();

  @override
  SpawnDirectory? get spawnDirectory => null;
  @override
  int? get rootProcessId => null;
  @override
  Stream<List<int>> get output => out.stream;
  @override
  void start({
    required String workingDirectory,
    required TerminalProfile profile,
    int rows = 25,
    int columns = 80,
    Map<String, String> extraEnv = const <String, String>{},
  }) {}
  @override
  void write(List<int> data) => writes.add(utf8.decode(data));
  @override
  void resize(int rows, int columns) {}
  @override
  void acknowledgeOutput() {}
  @override
  Future<void> kill() => out.close();
}

/// Monitor que só guarda o callback: o teste decide qual harness "roda".
class _FakeMonitor implements TerminalHarnessMonitor {
  void Function(HarnessKind?)? onChange;

  @override
  void registerSession({
    required String sessionId,
    required int? Function() rootPid,
    String? wslDistro,
    required void Function(HarnessKind? newHarness) onHarnessChanged,
  }) => onChange = onHarnessChanged;
  @override
  void unregisterSession(String sessionId) {}
  @override
  void requestPoll({String? sessionId, bool urgent = false}) {}
  @override
  void setSessionVisible(String sessionId, bool visible) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

({TerminalSession tab, _PtyGateway pty, _FakeMonitor monitor}) _tab(
  String id, {
  HarnessKind? harness,
  String? label,
}) {
  final pty = _PtyGateway();
  final monitor = _FakeMonitor();
  final tab = TerminalSession(
    id: id,
    projectId: 'ws',
    workingDirectory: '/repo',
    gateway: pty,
    monitor: monitor,
    profile: const TerminalProfile(
      id: 'login-shell',
      label: 'sh (login)',
      executable: '/bin/sh',
      args: ['-l'],
    ),
  )..restoreManualLabel(label);
  monitor.onChange!(harness);
  return (tab: tab, pty: pty, monitor: monitor);
}

void main() {
  test('aba de Pi: harness `pi` no list-tabs/peers e nó no grafo', () async {
    final pi = _tab('t1', harness: HarnessKind.pi, label: 'Pi');
    final shell = _tab('t2');
    final claude = _tab('t3', harness: HarnessKind.claudeCode);
    final tabs = [pi.tab, shell.tab, claude.tab];

    expect(agentHarnessName(pi.tab), 'pi');
    expect(agentHarnessName(shell.tab), isNull);
    expect(agentKindLabel(pi.tab), 'Pi');
    expect(
      workspaceAgentNodes(AgentGraphStore(), 'ws', tabs).map((s) => s.id),
      ['t1', 't3'],
      reason: 'shell puro não vira nó',
    );

    final graph = AgentGraphStore()..addLink('ws', 't3', 't1');
    final peers = agentPeers(graph, claude.tab, tabs);
    expect(peers.single['id'], 't1');
    expect(peers.single['label'], 'Pi');
    expect(peers.single['harness'], 'pi');
    expect(
      linkIntroText(pi.tab),
      'You are now connected to Pi (Pi). Talk to it with: '
      'cockpit msg --to Pi "..."',
    );
    graph.dispose();
    for (final t in tabs) {
      await t.dispose();
    }
  });

  test('cockpit msg pra aba de Pi: texto no PTY, Enter 400ms depois, log', () {
    fakeAsync((async) {
      final pi = _tab('t1', harness: HarnessKind.pi, label: 'Pi');
      final sender = _tab('t2', harness: HarnessKind.claudeCode, label: 'Rev');
      final log = AgentMessageLog();
      deliverAgentMessage(
        log: log,
        from: sender.tab,
        target: pi.tab,
        senderName: 'Rev',
        senderHarness: agentKindLabel(sender.tab),
        text: 'review feat/x',
        targetAlive: () => true,
      );
      // O TUI do Pi trata `\r` no mesmo write como Enter no meio do texto:
      // o Enter vai separado, depois do texto já processado.
      expect(pi.pty.writes, ['[from: Rev · Claude Code] review feat/x']);
      async.elapse(kAgentMessageSubmitDelay - const Duration(milliseconds: 1));
      expect(pi.pty.writes, hasLength(1));
      async.elapse(const Duration(milliseconds: 1));
      expect(pi.pty.writes.last, '\r');
      final m = log.forWorkspace('ws').single;
      expect((m.fromTabId, m.toTabId), ('t2', 't1'));
      expect(m.signedBy, 'Rev · Claude Code');
      expect(m.preview, 'review feat/x');
      log.dispose();
      unawaited(pi.tab.dispose());
      unawaited(sender.tab.dispose());
      async.flushMicrotasks();
    });
  });

  group('status de turno do Pi', () {
    void out(_PtyGateway pty, FakeAsync async) {
      pty.out.add(utf8.encode('x'));
      async.flushMicrotasks();
    }

    test('sem a extensão: heurística de saída', () {
      fakeAsync((async) {
        final pi = _tab('t1', harness: HarnessKind.pi);
        expect(pi.tab.usesOutputHeuristic, isTrue);
        out(pi.pty, async);
        expect(pi.tab.isWorking, isTrue);
        async.elapse(TerminalSession.outputSilenceIdle * 3);
        expect(pi.tab.isWorking, isFalse);
        unawaited(pi.tab.dispose());
        async.flushMicrotasks();
      });
    });

    test('com a extensão: o hook manda, a saída não', () {
      fakeAsync((async) {
        final pi = _tab('t1', harness: HarnessKind.pi);
        var finished = 0;
        pi.tab.onTurnFinished = () => finished++;
        out(pi.pty, async); // TUI desenhando ao subir: heurística acende
        expect(pi.tab.isWorking, isTrue);
        // `session_start` → SessionStart: desliga a heurística, sem aviso.
        pi.tab.applyClaudeStatus(
          status: TerminalStatus.idle,
          sessionId: '01a14730-3bd4',
          harness: AgentHarness.fromWire('pi'),
        );
        async.elapse(const Duration(milliseconds: 100));
        expect(pi.tab.isWorking, isFalse);
        expect(pi.tab.usesOutputHeuristic, isFalse);
        expect(finished, 0);
        expect(pi.tab.agentHarness, AgentHarness.pi);
        expect(
          pi.tab.agentHarness.resumeCommand(pi.tab.claudeSessionId!),
          'pi --session 01a14730-3bd4',
        );
        out(pi.pty, async); // redesenho não é turno
        expect(pi.tab.isWorking, isFalse);
        // `agent_start` → UserPromptSubmit; `agent_end` → Stop.
        pi.tab.applyClaudeStatus(
          status: TerminalStatus.working,
          isTurnStart: true,
          harness: AgentHarness.pi,
        );
        expect(pi.tab.isWorking, isTrue);
        async.elapse(TerminalSession.outputSilenceIdle * 3);
        expect(pi.tab.isWorking, isTrue, reason: 'silêncio não encerra');
        pi.tab.applyClaudeStatus(
          status: TerminalStatus.idle,
          harness: AgentHarness.pi,
        );
        async.elapse(const Duration(milliseconds: 100));
        expect(pi.tab.isWorking, isFalse);
        expect(finished, 1);
        // Pi saiu: o próximo processo precisa reportar de novo.
        pi.monitor.onChange!(null);
        pi.monitor.onChange!(HarnessKind.pi);
        expect(pi.tab.usesOutputHeuristic, isTrue);
        unawaited(pi.tab.dispose());
        async.flushMicrotasks();
      });
    });
  });
}
