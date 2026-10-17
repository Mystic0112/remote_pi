import 'package:cockpit/app/cockpit/domain/contracts/desktop_agent_apps.dart';
import 'package:cockpit/app/cockpit/domain/entities/desktop_agent_app.dart';
import 'package:cockpit/app/cockpit/ui/session/external_agent.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/cockpit_viewmodel.dart';
import 'package:cockpit/app/cockpit/ui/widgets/agent_graph_parts.dart';
import 'package:cockpit/app/cockpit/ui/widgets/confirm_dialog.dart';
import 'package:cockpit/app/core/domain/result.dart';
import 'package:cockpit/app/core/ui/settings_controller.dart';
import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/i18n/strings.g.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Grava a entrada MCP de [i] (backup antes). Codex: o boot volta a garanti-la
/// (`AppSettings.codexMcpIntegration`), já que o usuário a quis de novo.
Future<Result<void, DesktopAppError>> addDesktopIntegration(
  DesktopAgentApps apps,
  SettingsController settings,
  DesktopAppIntegration i,
) async {
  final r = await apps.install(i);
  if (r is Success && i.app == DesktopAgentApp.codexDesktop) {
    settings.setCodexMcpIntegration(true);
  }
  return r;
}

/// Tira só a entrada `cockpit` do config de [i] (backup antes). Codex: a
/// entrada é a mesma do Codex das abas e o instalador de hooks a recolocaria
/// no próximo boot — a remoção também desliga isso.
Future<Result<void, DesktopAppError>> removeDesktopIntegration(
  DesktopAgentApps apps,
  SettingsController settings,
  DesktopAppIntegration i,
) async {
  final r = await apps.uninstall(i);
  if (r is Success && i.app == DesktopAgentApp.codexDesktop) {
    settings.setCodexMcpIntegration(false);
  }
  return r;
}

/// "Remove from canvas" de um nó externo: tira do canvas e, se o usuário
/// marcar (só aparece quando o config tem a entrada), a integração do app.
Future<void> removeExternalNode(
  BuildContext context,
  CockpitViewModel vm,
  String ws,
  ExternalAgent e,
) async {
  final settings = context.read<SettingsController>();
  final integration = (await vm.desktopApps.integrations())
      .where((i) => i.app == e.app && i.configured)
      .firstOrNull;
  if (!context.mounted) return;
  final alsoIntegration = await _confirmRemoveNode(context, e, integration);
  if (alsoIntegration == null || !context.mounted) return;
  vm.agentGraph.removeExternal(ws, e.id);
  if (!alsoIntegration || integration == null) return;
  final r = await removeDesktopIntegration(
    vm.desktopApps,
    settings,
    integration,
  );
  if (!context.mounted) return;
  showGraphToast(context, switch (r) {
    Failure(:final error) => desktopAppErrorMessage(context, error),
    Success() => context.t.cockpit.desktopIntegration.removed(app: e.app.label),
  });
}

/// `null` = cancelou; senão, se a integração sai junto. Sem entrada no
/// config ([i] `null`), só a confirmação do canvas.
Future<bool?> _confirmRemoveNode(
  BuildContext context,
  ExternalAgent e,
  DesktopAppIntegration? i,
) {
  final tr = context.t.cockpit.desktopIntegration;
  var also = false;
  return showDialog<bool>(
    context: context,
    barrierColor: context.colors.scrim,
    builder: (context) {
      final colors = context.colors;
      final small = context.typo.label.copyWith(color: colors.text3);
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(
            tr.removeNodeTitle(name: e.displayTitle),
            style: context.typo.title.copyWith(
              fontSize: 15,
              color: colors.text,
            ),
          ),
          content: i == null
              ? null
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Checkbox(
                            state: also
                                ? CheckboxState.checked
                                : CheckboxState.unchecked,
                            onChanged: (s) => setState(
                              () => also = s == CheckboxState.checked,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setState(() => also = !also),
                              child: Text(
                                tr.removeNodeAlso(app: e.app.label),
                                style: context.typo.body.copyWith(
                                  color: colors.text,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      SelectableText(i.configPath, style: small),
                      if (also && i.app == DesktopAgentApp.codexDesktop) ...[
                        const SizedBox(height: 8),
                        Text(tr.codexNote, style: small),
                      ],
                    ],
                  ),
                ),
          actions: [
            OutlineButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.t.common.cancel),
            ),
            DestructiveButton(
              onPressed: () => Navigator.of(context).pop(also),
              child: Text(context.t.common.remove),
            ),
          ],
        ),
      );
    },
  );
}

/// Confirmação do "Remove" de Configurações (caminho do arquivo e, no Codex,
/// o que acontece com o Codex das abas).
Future<bool> confirmRemoveDesktopIntegration(
  BuildContext context,
  DesktopAppIntegration i,
) {
  final tr = context.t.cockpit.desktopIntegration;
  return showConfirmDialog(
    context,
    title: tr.removeTitle(app: i.app.label),
    message: [
      tr.removeMessage(path: i.configPath),
      if (i.app == DesktopAgentApp.codexDesktop) tr.codexNote,
    ].join('\n\n'),
    confirmLabel: context.t.common.remove,
    danger: true,
  );
}
