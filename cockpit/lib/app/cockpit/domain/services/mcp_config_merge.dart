import 'dart:convert';

/// Nome da entrada do Cockpit nos configs MCP dos apps desktop. Só ela é
/// escrita; os outros servidores do usuário nunca são tocados.
const String kMcpServerName = 'cockpit';

/// `args` da entrada: `cockpit mcp --agent <app-id>`.
List<String> mcpServerArgs(String appId) => ['mcp', '--agent', appId];

/// Trecho JSON mostrado no dialog: `"cockpit": {...}`.
String jsonMcpEntry({required String command, required List<String> args}) =>
    '"$kMcpServerName": '
    '${const JsonEncoder.withIndent('  ').convert({'command': command, 'args': args})}';

/// Envs que o Codex repassa ao `cockpit mcp` (`env_vars`): sem isto ele limpa
/// o ambiente do servidor MCP. Rodando sob uma aba, o processo herda a
/// identidade e o socket do app daquela aba (o flavor certo); no app desktop
/// elas não existem e o Codex só as ignora.
const List<String> kCodexMcpEnvVars = [
  'COCKPIT_TAB_ID',
  'COCKPIT_STATUS_SOCK',
  'COCKPIT_STATUS_PORT',
  'COCKPIT_STATUS_TOKEN',
];

/// Tabela TOML do Codex (`~/.codex/config.toml`). A mesma entrada serve o app
/// desktop (nó `ext:codex-desktop`) e o Codex CLI das abas: o `cockpit mcp`
/// descobre sozinho se roda sob uma aba.
String tomlMcpEntry({required String command, required List<String> args}) =>
    // String JSON é string básica TOML válida (aspas e `\` escapados).
    '[mcp_servers.$kMcpServerName]\n'
    'command = ${jsonEncode(command)}\n'
    'args = [${args.map(jsonEncode).join(', ')}]\n'
    'env_vars = [${kCodexMcpEnvVars.map(jsonEncode).join(', ')}]\n';

/// Põe `mcpServers.cockpit` = {command, args} no JSON [raw] (`null`/vazio =
/// arquivo novo), preservando todas as outras chaves e a ordem delas. Reindenta
/// com a indentação que o arquivo já usava. Idempotente.
///
/// [FormatException] quando [raw] não é um objeto JSON (JSONC com comentário,
/// lixo): melhor recusar do que reescrever o config do usuário errado.
String mergeJsonMcpServer(
  String? raw, {
  required String command,
  required List<String> args,
}) {
  final blank = raw == null || raw.trim().isEmpty;
  final Object? decoded = blank ? <String, Object?>{} : jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('not a JSON object');
  }
  final servers = decoded['mcpServers'] ?? <String, Object?>{};
  if (servers is! Map) {
    throw const FormatException('mcpServers is not an object');
  }
  servers[kMcpServerName] = {'command': command, 'args': args};
  decoded['mcpServers'] = servers;
  final out = JsonEncoder.withIndent(
    blank ? '  ' : _indentOf(raw),
  ).convert(decoded);
  return blank || raw.endsWith('\n') ? '$out\n' : out;
}

/// Indentação da primeira linha indentada; 2 espaços se não houver.
String _indentOf(String raw) {
  for (final line in raw.split('\n').skip(1)) {
    final indent = RegExp(r'^[ \t]+').stringMatch(line);
    if (indent != null) return indent;
  }
  return '  ';
}

final _cockpitHeader = RegExp(
  r'^[ \t]*\[[ \t]*mcp_servers[ \t]*\.[ \t]*"?cockpit"?[ \t]*\][ \t]*(#[^\n]*)?\r?$',
  multiLine: true,
);

// ponytail: linha `[...]` = cabeçalho de tabela; um array multilinha com uma
// linha só `[1, 2]` (sem vírgula) seria confundido — raro em config de MCP.
final _anyHeader = RegExp(
  r'^[ \t]*\[\[?[^\]\n]*\]\]?[ \t]*(#[^\n]*)?\r?$',
  multiLine: true,
);

/// Troca (ou acrescenta no fim) só a tabela `[mcp_servers.cockpit]` do TOML
/// [raw]; todo o resto fica byte a byte igual. Subtabelas do usuário
/// (`[mcp_servers.cockpit.env]`) ficam. Idempotente.
///
/// [FormatException] quando `cockpit` já está definido de outro jeito (chave
/// pontilhada, dentro de `[mcp_servers]`): acrescentar a tabela duplicaria a
/// chave e quebraria o config inteiro.
String mergeTomlMcpServer(
  String? raw, {
  required String command,
  required List<String> args,
}) {
  final text = raw ?? '';
  final table = tomlMcpEntry(command: command, args: args);
  final m = _cockpitHeader.firstMatch(text);
  if (m == null) {
    _rejectOtherDefinitions(text);
    if (text.isEmpty) return table;
    return '$text${text.endsWith('\n') ? '' : '\n'}\n$table';
  }
  final next = _anyHeader.allMatches(text, m.end).firstOrNull;
  final end = _bodyEnd(text, m.end, next?.start ?? text.length);
  return '${text.substring(0, m.start)}$table${text.substring(end)}';
}

/// Fim do corpo da tabela que vai de [from] (fim do cabeçalho) a [to] (próximo
/// cabeçalho): comentários e linhas em branco no fim ficam de fora — são do
/// que vem depois (ex.: o `# >>> cockpit hooks` do bloco de trust, que sumiria
/// e duplicaria o bloco inteiro no próximo boot).
int _bodyEnd(String text, int from, int to) {
  var end = to;
  while (end > from) {
    final lineStart = text.lastIndexOf('\n', end - 2) + 1;
    if (lineStart <= from) break;
    final line = text.substring(lineStart, end).trim();
    if (line.isNotEmpty && !line.startsWith('#')) break;
    end = lineStart;
  }
  return end;
}

void _rejectOtherDefinitions(String text) {
  final dotted = RegExp(
    r'^[ \t]*mcp_servers[ \t]*\.[ \t]*"?cockpit"?[ \t]*[.=]',
    multiLine: true,
  );
  if (dotted.hasMatch(text)) {
    throw const FormatException('mcp_servers.cockpit defined as a dotted key');
  }
  final parent = RegExp(
    r'^[ \t]*\[[ \t]*mcp_servers[ \t]*\][ \t]*(#[^\n]*)?\r?$',
    multiLine: true,
  ).firstMatch(text);
  if (parent == null) return;
  final end = _anyHeader.allMatches(text, parent.end).firstOrNull?.start;
  final body = text.substring(parent.end, end ?? text.length);
  if (RegExp(r'^[ \t]*"?cockpit"?[ \t]*[.=]', multiLine: true).hasMatch(body)) {
    throw const FormatException('cockpit defined inside [mcp_servers]');
  }
}

/// Tira só `mcpServers.cockpit` do JSON [raw]; o resto fica byte a byte (a
/// entrada sai com a vírgula e a linha dela). Sem a entrada: [raw] intacto.
/// Se o corte textual não bater com o JSON esperado (chave duplicada, por
/// exemplo), reescreve como o [mergeJsonMcpServer] faz.
///
/// [FormatException] quando [raw] não é um objeto JSON.
String removeJsonMcpServer(String raw) {
  if (raw.trim().isEmpty) return raw;
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('not a JSON object');
  }
  final servers = decoded['mcpServers'];
  if (servers is! Map || !servers.containsKey(kMcpServerName)) return raw;
  servers.remove(kMcpServerName);
  final cut = _cutJsonMember(raw, const ['mcpServers', kMcpServerName]);
  if (cut != null && jsonEncode(jsonDecode(cut)) == jsonEncode(decoded)) {
    return cut;
  }
  final out = JsonEncoder.withIndent(_indentOf(raw)).convert(decoded);
  return raw.endsWith('\n') ? '$out\n' : out;
}

/// [s] sem o membro em [path] (objetos aninhados a partir da raiz), levando a
/// vírgula vizinha e, se a chave abria a linha, a linha inteira. `null` = não
/// achou (o chamador cai na reescrita).
String? _cutJsonMember(String s, List<String> path) {
  var i = 0;
  void ws() {
    while (i < s.length && ' \t\r\n'.contains(s[i])) {
      i++;
    }
  }

  // Pula uma string JSON (i no `"`) respeitando escapes; devolve o conteúdo.
  String str() {
    final start = i++;
    while (s[i] != '"') {
      i += s[i] == r'\' ? 2 : 1;
    }
    i++;
    return jsonDecode(s.substring(start, i)) as String;
  }

  void value() {
    ws();
    if (s[i] == '"') {
      str();
      return;
    }
    if (s[i] == '{' || s[i] == '[') {
      var depth = 0;
      do {
        final c = s[i];
        if (c == '"') {
          str();
          continue;
        }
        if (c == '{' || c == '[') depth++;
        if (c == '}' || c == ']') depth--;
        i++;
      } while (depth > 0);
      return;
    }
    while (i < s.length && !',}] \t\r\n'.contains(s[i])) {
      i++;
    }
  }

  try {
    for (var level = 0; level < path.length; level++) {
      ws();
      if (s[i] != '{') return null;
      final open = i++;
      int? prevComma;
      for (;;) {
        ws();
        if (s[i] == '}') return null;
        final keyStart = i;
        final key = str();
        ws();
        i++; // `:`
        if (key != path[level]) {
          value();
          ws();
          if (s[i] != ',') return null;
          prevComma = i++;
          continue;
        }
        if (level < path.length - 1) break; // desce no valor
        value();
        final valueEnd = i;
        ws();
        if (s[i] == ',') {
          var start = keyStart;
          while (start > 0 && ' \t'.contains(s[start - 1])) {
            start--;
          }
          final ownLine = start == 0 || s[start - 1] == '\n';
          if (!ownLine) start = keyStart;
          var end = i + 1;
          while (end < s.length && ' \t'.contains(s[end])) {
            end++;
          }
          if (ownLine && s.startsWith('\r\n', end)) end += 2;
          if (ownLine && s.startsWith('\n', end)) end++;
          return s.replaceRange(start, end, '');
        }
        return s.replaceRange(prevComma ?? open + 1, valueEnd, '');
      }
    }
  } on RangeError {
    return null;
  }
  return null;
}

/// Cabeçalho da tabela do Cockpit ou de uma subtabela dela
/// (`[mcp_servers.cockpit.env]`).
final _cockpitTables = RegExp(
  r'^[ \t]*\[[ \t]*mcp_servers[ \t]*\.[ \t]*"?cockpit"?[ \t]*(\.[^\]\n]*)?\][ \t]*(#[^\n]*)?\r?$',
  multiLine: true,
);

/// Tira a tabela `[mcp_servers.cockpit]` (com o `env_vars`) e as subtabelas
/// dela — sem a principal, uma `[mcp_servers.cockpit.env]` órfã viraria um
/// servidor sem `command` e quebraria o config. O resto fica byte a byte; é o
/// inverso exato do append do [mergeTomlMcpServer] (a linha em branco que ele
/// pôs antes sai junto). Sem a tabela: [raw] intacto.
String removeTomlMcpServer(String raw) {
  var text = raw;
  for (;;) {
    final m = _cockpitTables.firstMatch(text);
    if (m == null) return text;
    final next = _anyHeader.allMatches(text, m.end).firstOrNull;
    final end = _bodyEnd(text, m.end, next?.start ?? text.length);
    final blankBefore = m.start >= 2 && text.startsWith('\n\n', m.start - 2);
    final start = blankBefore ? m.start - 1 : m.start;
    text = text.replaceRange(start, end, '');
  }
}
