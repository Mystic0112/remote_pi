import 'package:cockpit/app/cockpit/domain/entities/agent_message.dart';
import 'package:flutter/foundation.dart';

/// Log em memória das [AgentMessage] por workspace, das mais antigas às mais
/// novas. Não persiste: some ao fechar o app.
class AgentMessageLog extends ChangeNotifier {
  /// Teto por workspace; acima disso a mais antiga sai.
  static const int maxPerWorkspace = 500;

  /// Tamanho da prévia guardada (o texto inteiro já foi pro PTY do alvo).
  static const int previewLength = 200;

  final Map<String, List<AgentMessage>> _byWorkspace = {};

  List<AgentMessage> forWorkspace(String workspaceId) =>
      List.unmodifiable(_byWorkspace[workspaceId] ?? const <AgentMessage>[]);

  /// Registra [text] de [fromTabId] para [toTabId] em cada workspace
  /// envolvido (o do emissor e, se diferente, o do alvo).
  AgentMessage record({
    required String fromTabId,
    required String fromWorkspaceId,
    required String toTabId,
    required String toWorkspaceId,
    required String text,
    String? signedBy,
  }) {
    final message = AgentMessage(
      fromTabId: fromTabId,
      toTabId: toTabId,
      sentAt: DateTime.now(),
      preview: text.length > previewLength
          ? text.substring(0, previewLength)
          : text,
      signedBy: signedBy,
    );
    for (final ws in {fromWorkspaceId, toWorkspaceId}) {
      final list = _byWorkspace.putIfAbsent(ws, () => <AgentMessage>[]);
      list.add(message);
      if (list.length > maxPerWorkspace) list.removeAt(0);
    }
    notifyListeners();
    return message;
  }
}
