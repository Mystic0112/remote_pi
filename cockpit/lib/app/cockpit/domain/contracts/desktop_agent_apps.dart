import 'package:cockpit/app/cockpit/domain/entities/desktop_agent_app.dart';
import 'package:cockpit/app/core/domain/result.dart';

/// Apps desktop de agente (Claude Desktop, Cursor, Antigravity, Codex/ChatGPT)
/// como nós externos do grafo: detecção, a entrada MCP no config de cada um e
/// abrir/trazer o app pra frente.
abstract class DesktopAgentApps {
  /// Apps instalados nesta máquina, com o config e a entrada que a integração
  /// grava (o dialog mostra antes de gravar).
  Future<List<DesktopAppIntegration>> detect();

  /// Backup do config (`<arquivo>.cockpit-bak-<timestamp>`) e merge só da
  /// entrada `cockpit`. Idempotente; nunca toca os outros servidores.
  Future<Result<void, DesktopAppError>> install(DesktopAppIntegration app);

  /// O que Configurações lista: os apps detectados e os que já têm a entrada
  /// `cockpit` no config mesmo sem o app (o Codex CLI sem o app desktop).
  Future<List<DesktopAppIntegration>> integrations();

  /// Backup do config e remoção só da entrada `cockpit` (o resto fica byte a
  /// byte). Nunca restaura um backup antigo: o que o usuário editou depois da
  /// integração fica. Sem a entrada: no-op.
  Future<Result<void, DesktopAppError>> uninstall(DesktopAppIntegration app);

  /// Abre o app (ou traz pra frente, se já aberto). IDEs recebem [folder].
  Future<void> launch(DesktopAgentApp app, String folder);
}
