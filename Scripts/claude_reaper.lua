-- Claude Console para REAPER
-- Janelinha docavel pra conversar com o Claude sem sair do REAPER.
--
-- Como funciona: chama o CLI do Claude Code em modo headless, liberando
-- SOMENTE as ferramentas do REAPER MCP (--allowedTools mcp__reaper).
-- Ou seja, ele mexe no REAPER e em mais nada: nao le nem escreve arquivo teu.
--
-- Requisitos: ReaImGui, o bridge reaper_mcp_bridge.lua RODANDO, e o CLI do Claude.
-- A chamada roda em segundo plano, entao a janela nao congela enquanto ele pensa.

------------------------------------------------------------------ config

local BS       = string.char(92)  -- barra invertida literal, imune a escape no fonte
local DIR      = reaper.GetResourcePath() .. '/Scripts/claude_console/'
local DIR_WIN  = DIR:gsub('/', BS)
local TIMEOUT  = 1800  -- 30 min. so existe pra nao ficar preso pra sempre se algo morrer

-- Qual CLI de IA a janela usa. O REAPER, o bridge do MCP e a ponte de
-- etiquetas sao agnosticos: so a janela sabe quem ela chama. Trocar de motor e
-- trocar esta linha, desde que exista uma entrada com esse nome em `motores`.
local MOTOR = 'claude'

-- Modelo. Medido com Claude Code: a mesma pergunta com uma leitura do projeto
-- levou 8667 ms no modelo padrao da conta e 6157 ms no haiku, 29% a menos,
-- com a mesma resposta.
-- Comando do dia a dia e curto e objetivo, entao o rapido e o padrao daqui.
-- Para usar o modelo forte numa mensagem, comece ela com "!".
-- Vazio em qualquer um dos dois = o padrao da conta naquele motor.
local MODELO       = nil   -- nil = usa o modelo rapido do motor
local MODELO_FORTE = nil   -- nil = usa o modelo forte do motor

-- Declarados aqui e definidos mais abaixo. Os motores usam estas duas, e elas
-- so existem depois; em Lua basta a variavel local ja existir quando a funcao
-- que a usa for ESCRITA, porque a chamada acontece em tempo de execucao.
local decodificar, extrai_result

------------------------------------------------------------------ motores

-- Tudo que e especifico de uma CLI mora aqui dentro. O resto da janela so
-- conhece eventos neutros:
--   {tipo='pronto'}                sessao iniciada, ja da sinal de vida
--   {tipo='tool',  nome='...'}     comecou a usar uma ferramenta
--   {tipo='texto', texto='...'}    pedaco da resposta chegando
--   {tipo='fim',   texto='...'}    acabou, com o texto final
--   {tipo='erro',  texto='...'}    deu ruim, com o motivo
--
-- Para plugar outro motor, acrescente uma entrada com os mesmos campos. Nada
-- fora desta secao precisa saber qual CLI esta rodando.

local motores = {}

motores.claude = {
  nome          = 'Claude Code',
  exe           = (os.getenv('APPDATA') or '') .. BS .. 'npm' .. BS .. 'claude.cmd',
  dica          = 'Instale com: npm install -g @anthropic-ai/claude-code',
  modelo_rapido = 'haiku',
  modelo_forte  = '',      -- vazio = o padrao da conta

  -- --strict-mcp-config + --mcp-config: carrega SO o servidor do REAPER. Sem
  -- isso, cada chamada sobe todos os MCP da conta e perde dezenas de segundos.
  -- --include-partial-messages: manda os pedacos do texto conforme saem.
  montar_comando = function(self, modelo, continuar)
    local m = (modelo and modelo ~= '') and (' --model ' .. modelo) or ''
    local c = continuar and ' --continue' or ''
    return 'call "' .. self.exe .. '" -p --output-format stream-json --verbose'
        .. ' --include-partial-messages --mcp-config "mcp-reaper.json"'
        .. ' --strict-mcp-config --allowedTools "mcp__reaper" "Skill"'
        .. m .. c .. ' < "prompt.txt" > "out.txt" 2>&1'
  end,

  traduzir = function(self, linha)
    if linha:find('"subtype":"init"', 1, true) then
      return { tipo = 'pronto' }
    end
    if linha:find('"type":"tool_use"', 1, true) then
      local nome = linha:match('"name":"([%w_]+)"')
      if nome then return { tipo = 'tool', nome = nome } end
      return nil
    end
    local i = linha:find('"text_delta"', 1, true)
    if i then
      local k = linha:find('"text":"', i, true)
      if k then
        local pedaco = decodificar(linha, k + 8)
        if pedaco then return { tipo = 'texto', texto = pedaco } end
      end
      return nil
    end
    if linha:find('"type":"result"', 1, true) then
      return { tipo = 'fim', texto = extrai_result(linha) }
    end
    return nil
  end,
}

local motor = motores[MOTOR]

------------------------------------------------------------------ checagens

if not reaper.ImGui_CreateContext then
  reaper.MB('ReaImGui nao encontrado.\n\nInstale pelo ReaPack:\nExtensions > ReaPack > Browse packages > "ReaImGui".',
            'Claude REAPER', 0)
  return
end

if not motor then
  reaper.MB('Motor "' .. tostring(MOTOR) .. '" nao existe neste script.\n\n' ..
            'Ajuste a variavel MOTOR no topo.', 'Claude REAPER', 0)
  return
end

local f = io.open(motor.exe, 'r')
if f then f:close() else
  reaper.MB('CLI do ' .. motor.nome .. ' nao encontrada em:\n' .. motor.exe ..
            '\n\n' .. (motor.dica or '') ..
            '\n\nOu ajuste o campo exe do motor, no topo do script.', 'Claude REAPER', 0)
  return
end

-- sem a barra final: com ela o RecursiveCreateDirectory pode recusar o caminho
reaper.RecursiveCreateDirectory(DIR:sub(1, -2), 0)

-- confere de verdade, escrevendo um arquivo. se nao der, avisa agora em vez
-- de abrir a janela e so quebrar na hora de enviar
local teste = io.open(DIR .. 'ok.tmp', 'wb')
if not teste then
  reaper.MB('Nao consegui criar a pasta de trabalho: ' .. DIR, 'Claude REAPER', 0)
  return
end
teste:close()
os.remove(DIR .. 'ok.tmp')

------------------------------------------------------------------ bridge

-- o bridge e quem executa de verdade no REAPER, e ele morre quando o REAPER fecha.
-- em vez de exigir que voce rode os dois na mao, a janela sobe ele sozinha.
-- o proprio bridge escreve um heartbeat; se estiver fresco, ja tem copia rodando.
local function bridge_vivo()
  local b = tonumber(reaper.GetExtState('TwelveTake_REAPER_MCP', 'heartbeat'))
  return b ~= nil and (reaper.time_precise() - b) < 2
end

if not bridge_vivo() then
  -- preferir disparar como ACTION: assim o bridge vira script independente e
  -- continua vivo mesmo se esta janela for fechada
  -- O Command ID de um ReaScript e "_RS" mais o SHA-1 do NOME do arquivo em
  -- MAIUSCULAS, sem caminho nenhum: sha1('REAPER_MCP_BRIDGE.LUA') da exatamente
  -- o id abaixo. Conferido em tres scripts diferentes. Ou seja, este ID vale em
  -- qualquer maquina que tenha o bridge com esse nome, e voce nao precisa
  -- descobrir o seu. Se o seu arquivo tiver outro nome, o fallback abaixo
  -- carrega o arquivo direto e funciona do mesmo jeito.
  local cmd = reaper.NamedCommandLookup('_RS70b9b9e08b3a1b47bef354e4c40290516371e9f9')
  if cmd and cmd ~= 0 then
    reaper.Main_OnCommand(cmd, 0)
  else
    local fn = loadfile(reaper.GetResourcePath() .. '/Scripts/reaper_mcp_bridge.lua')
    if fn then pcall(fn) end
  end
end

------------------------------------------------------------------ helpers de API (compat entre versoes do ReaImGui)

local function pick(...)
  -- select('#',...) em vez de ipairs: a lista tem nil no meio quando a
  -- versao do ReaImGui nao tem uma das funcoes, e ipairs pararia ali
  for i = 1, select('#', ...) do
    local fn = select(i, ...)
    if type(fn) == 'function' then return fn() end
  end
  return 0
end

local COND_FIRST = pick(reaper.ImGui_Cond_FirstUseEver)
local COND_SEMPRE = pick(reaper.ImGui_Cond_Always)
local MOD_CTRL   = pick(reaper.ImGui_Mod_Ctrl, reaper.ImGui_ModFlags_Ctrl)
local MOD_SHIFT  = pick(reaper.ImGui_Mod_Shift, reaper.ImGui_ModFlags_Shift)
local KEY_ENTER  = pick(reaper.ImGui_Key_Enter)

-- EnterReturnsTrue: Enter envia. CtrlEnterForNewLine: Ctrl+Enter quebra linha.
-- Juntas elas invertem o padrao do ImGui multilinha: Enter envia, como num chat.
local FLAGS_ENTRADA = pick(reaper.ImGui_InputTextFlags_EnterReturnsTrue) |
                      pick(reaper.ImGui_InputTextFlags_CtrlEnterForNewLine)
local FLAGS_LEITURA = pick(reaper.ImGui_InputTextFlags_ReadOnly)

------------------------------------------------------------------ arquivos

local function write_file(path, txt)
  local fh = io.open(path, 'wb')
  if not fh then return false end
  fh:write(txt)
  fh:close()
  return true
end

local function read_file(path)
  local fh = io.open(path, 'rb')
  if not fh then return nil end
  local t = fh:read('*a')
  fh:close()
  return t
end

local function file_size(path)
  local fh = io.open(path, 'rb')
  if not fh then return -1 end
  local n = fh:seek('end')
  fh:close()
  return n
end

local function file_exists(path)
  local fh = io.open(path, 'rb')
  if fh then fh:close() return true end
  return false
end

------------------------------------------------------------------ estado

local ctx      = reaper.ImGui_CreateContext('Claude REAPER')
local input    = ''
local log      = {}
local busy     = false
local started  = 0
local nova     = true      -- proxima chamada comeca conversa nova
local status   = 'pronto'
local last_change = 0
local dock     = false
local geracao  = 0        -- muda o ID do campo pra forcar o ImGui a largar o buffer
local focar    = false    -- devolve o cursor pra caixa no frame seguinte
local atividade = nil     -- ferramenta que ele esta chamando agora

-- streaming: em vez de esperar o fim e mostrar tudo de uma vez, o out.txt e
-- lido do ponto onde parei e os eventos viram status e texto na tela.
local stream_pos  = 0     -- quanto do out.txt ja foi processado
local sobra       = ''    -- ultima linha incompleta, esperando o resto
local parcial     = ''    -- resposta que esta chegando, pedaco a pedaco
local modelo_usado = ''   -- qual modelo respondeu a mensagem atual

-- o historico vira UMA string pra caber numa caixa somente-leitura,
-- que e o que permite selecionar e copiar com Ctrl+C
local function historico_txt()
  local partes = {}
  for i = 1, #log do
    local e = log[i]
    local prefixo = ''
    if e.papel == 'voce' then prefixo = '> '
    elseif e.papel == 'erro' then prefixo = '[erro] '
    elseif e.papel == 'info' then prefixo = '[info] ' end
    partes[#partes + 1] = prefixo .. e.texto
  end
  -- a resposta que esta chegando entra no fim, para a tela se mexer enquanto
  -- ele escreve em vez de so aparecer tudo no final
  if busy and parcial ~= '' then
    partes[#partes + 1] = parcial
  end
  return table.concat(partes, string.char(10) .. string.char(10))
end

local function add(papel, texto)
  log[#log + 1] = { papel = papel, texto = texto }
end

-- O InputTextMultiline do ImGui NAO quebra linha: ele rola pro lado, e ler a
-- resposta virava esticar a janela inteira. Trocar por texto comum resolveria
-- a quebra, mas tiraria o Ctrl+C do historico. Entao a quebra e feita aqui, na
-- largura atual da janela, e o texto continua numa caixa selecionavel.
--
-- O resultado fica em cache: so recalcula quando o texto ou a largura mudam,
-- senao seria uma varredura de string a cada frame.
local cache_quebra = { largura = -1, origem = nil, saida = '' }

local function quebrar(ctx, texto, largura)
  -- versao de ReaImGui sem medida de texto: devolve como estava, sem quebrar.
  -- Melhor rolar pro lado do que a janela nao abrir.
  if not reaper.ImGui_CalcTextSize then return texto end

  if cache_quebra.largura == largura and cache_quebra.origem == texto then
    return cache_quebra.saida
  end

  local NL = string.char(10)
  local saida = {}

  for linha in (texto .. NL):gmatch('([^' .. NL .. ']*)' .. NL) do
    if linha == '' then
      saida[#saida + 1] = ''
    else
      local atual = ''
      for palavra in linha:gmatch('%S+') do
        local teste = (atual == '') and palavra or (atual .. ' ' .. palavra)
        local w = reaper.ImGui_CalcTextSize(ctx, teste)
        if w > largura and atual ~= '' then
          saida[#saida + 1] = atual
          atual = palavra
        else
          atual = teste
        end
      end
      saida[#saida + 1] = atual
    end
  end

  local resultado = table.concat(saida, NL)
  cache_quebra = { largura = largura, origem = texto, saida = resultado }
  return resultado
end

------------------------------------------------------------------ envio

local function enviar(prompt)
  if busy or prompt == '' then return end

  os.remove(DIR .. 'done.flag')
  os.remove(DIR .. 'out.txt')

  -- "!" no comeco da mensagem manda no modelo forte. O "!" nao vai no prompt.
  local escolhido = MODELO or motor.modelo_rapido
  if prompt:sub(1, 1) == '!' then
    escolhido = MODELO_FORTE or motor.modelo_forte
    prompt = prompt:sub(2):gsub('^%s+', '')
    if prompt == '' then return end
  end
  escolhido = escolhido or ''
  modelo_usado = (escolhido ~= '') and escolhido or 'padrao'

  if not write_file(DIR .. 'prompt.txt', prompt) then
    add('erro', 'nao consegui escrever em ' .. DIR)
    return
  end

  local bat = table.concat({
    '@echo off',
    'chcp 65001 >nul',
    -- sem a barra final: no cmd, barra antes de aspa escapa a aspa
    'cd /d "' .. DIR_WIN:sub(1, -2) .. '"',
    -- quem monta a linha e o motor: a janela nao sabe as flags de ninguem.
    -- 'call' e obrigatorio e por isso mora aqui: sem ele, chamar um .cmd de
    -- dentro de um .bat entrega o controle e nunca volta, e a done.flag nunca
    -- seria escrita.
    motor:montar_comando(escolhido, not nova),
    'echo done> "done.flag"',
  }, '\r\n') .. '\r\n'

  if not write_file(DIR .. 'run.bat', bat) then
    add('erro', 'nao consegui escrever o run.bat')
    return
  end

  add('voce', prompt)
  last_change = reaper.time_precise()
  stream_pos  = 0
  sobra       = ''
  parcial     = ''
  busy    = true
  started = reaper.time_precise()
  status  = 'conectando'
  -- roda via .vbs com janela oculta (o 0 no Run): sem terminal piscando na tela.
  -- se o .vbs falhar, cai no cmd normal em vez de nao rodar nada.
  local vbs = 'CreateObject("WScript.Shell").Run "cmd /c ""' .. DIR_WIN .. 'run.bat""", 0, False'
  if write_file(DIR .. 'run.vbs', vbs) then
    reaper.ExecProcess('wscript.exe "' .. DIR_WIN .. 'run.vbs"', -1)
  else
    reaper.ExecProcess('cmd.exe /C "' .. DIR_WIN .. 'run.bat"', -1)
  end
end

-- O claude responde em JSONL (stream-json). Duas coisas interessam:
--   "name":"mcp__reaper__xxx"  -> qual ferramenta ele esta usando agora
--   "result":"..."             -> o texto final, quando termina
-- Nao da pra usar match simples no result: ele tem aspas e quebras escapadas,
-- entao percorro caractere a caractere ate a aspa nao escapada.
-- sem "local": atribui a variavel local declarada la no topo, que os motores
-- ja capturaram. Se levar "local" aqui, vira outra variavel e eles veem nil.
function decodificar(txt, j)
  local buf = {}
  while j <= #txt do
    local c = txt:sub(j, j)
    if c == string.char(92) then
      local n = txt:sub(j + 1, j + 1)
      if n == 'n' then buf[#buf + 1] = string.char(10)
      elseif n == 't' then buf[#buf + 1] = string.char(9)
      elseif n == 'r' then buf[#buf + 1] = ''
      elseif n == 'u' then
        local cod = tonumber(txt:sub(j + 2, j + 5), 16)
        if cod and cod < 128 then buf[#buf + 1] = string.char(cod) end
        j = j + 4
      else buf[#buf + 1] = n end
      j = j + 2
    elseif c == string.char(34) then
      return table.concat(buf)
    else
      buf[#buf + 1] = c
      j = j + 1
    end
  end
  return nil   -- aspas nao fecharam: ainda esta escrevendo
end

-- a ULTIMA ocorrencia da marca: o evento final e a ultima linha do stream
function extrai_result(txt)
  local marca = '"result":"'
  local i, pos = nil, 1
  while true do
    local k = txt:find(marca, pos, true)
    if not k then break end
    i, pos = k, k + 1
  end
  if not i then return nil end
  return decodificar(txt, i + #marca)
end

-- Le SO o pedaco do out.txt que ainda nao foi processado. Com
-- --include-partial-messages o arquivo ganha um evento por pedacinho de texto,
-- e reparsar o arquivo inteiro a cada frame (dezenas de vezes por segundo)
-- deixaria a janela pesada justamente quando a resposta e longa.
local function ler_novo(path, pos)
  local fh = io.open(path, 'rb')
  if not fh then return nil, pos end
  local sz = fh:seek('end')
  if sz <= pos then fh:close() return '', pos end
  fh:seek('set', pos)
  local novo = fh:read('*a') or ''
  fh:close()
  return novo, sz
end

-- nome tecnico de ferramenta vira frase que diz algo pra quem esta olhando
local TRADUCAO = {
  ToolSearch = 'procurando a ferramenta',
  Skill      = 'abrindo a skill',
}

local function nome_legivel(nome)
  if TRADUCAO[nome] then return TRADUCAO[nome] end
  local n = nome:match('^mcp__reaper__(.+)$') or nome
  if n:match('^get_') or n:match('^measure_') or n:match('^find_') then return 'lendo o projeto' end
  if n == 'insert_track' then return 'criando faixa' end
  if n == 'delete_track' then return 'apagando faixa' end
  if n:match('send') then return 'roteando' end
  if n:match('^track_fx_') or n:match('^take_fx_') then return 'mexendo nos plugins' end
  if n:match('^set_eq') then return 'ajustando o EQ' end
  if n:match('^set_track_') or n:match('^arm_') then return 'ajustando a faixa' end
  if n:match('midi') then return 'escrevendo MIDI' end
  if n:match('^run_action') then return 'rodando uma action' end
  if n:match('marker') or n:match('tempo') or n:match('region') then return 'mexendo no tempo' end
  if n:match('^open_project') or n:match('^create_project') then return 'abrindo projeto' end
  return n
end

local function finalizar(texto)
  texto = (texto or ''):gsub('^%s+', ''):gsub('%s+$', '')
  if texto == '' then texto = (parcial or ''):gsub('^%s+', ''):gsub('%s+$', '') end
  if texto == '' then texto = '(resposta vazia)' end
  add('claude', texto)
  busy      = false
  nova      = false
  status    = 'pronto'
  atividade = nil
  parcial   = ''
  os.remove(DIR .. 'done.flag')
end

-- Traduz a linha pelo motor e reage ao evento neutro. Daqui pra baixo a janela
-- nao sabe mais com qual CLI esta falando.
-- Devolve true quando a conversa terminou nesta linha.
local function processar_linha(linha)
  if linha == '' then return false end

  local ok, ev = pcall(motor.traduzir, motor, linha)
  if not ok or not ev then return false end

  if ev.tipo == 'pronto' then
    status = 'pensando'

  elseif ev.tipo == 'tool' then
    atividade = nome_legivel(ev.nome)
    status    = 'trabalhando'
    -- O texto escrito ENTRE uma ferramenta e outra e narracao do raciocinio, e
    -- costuma sair em ingles ("The project is empty, so..."). Zerar aqui faz a
    -- janela mostrar so o texto que vem DEPOIS da ultima ferramenta, que e a
    -- resposta de verdade.
    parcial = ''

  elseif ev.tipo == 'texto' then
    parcial   = parcial .. (ev.texto or '')
    status    = 'escrevendo'
    atividade = nil

  elseif ev.tipo == 'fim' then
    finalizar(ev.texto)
    return true

  elseif ev.tipo == 'erro' then
    add('erro', ev.texto or 'o motor relatou um erro')
    busy      = false
    nova      = false
    status    = 'erro'
    atividade = nil
    parcial   = ''
    os.remove(DIR .. 'done.flag')
    return true
  end

  return false
end

local function checar_resposta()
  if not busy then return end

  local novo, pos = ler_novo(DIR .. 'out.txt', stream_pos)
  if novo and novo ~= '' then
    stream_pos  = pos
    last_change = reaper.time_precise()
    sobra = sobra .. novo
    -- processa so linhas inteiras: o pedaco lido pode ter cortado uma no meio
    while true do
      local nl = sobra:find(string.char(10), 1, true)
      if not nl then break end
      local linha = sobra:sub(1, nl - 1):gsub(string.char(13), '')
      sobra = sobra:sub(nl + 1)
      if processar_linha(linha) then return end
    end
  end

  -- rede de seguranca: processo terminou e eu nao vi o evento final
  local parado = stream_pos > 0 and (reaper.time_precise() - last_change) > 10
  if file_exists(DIR .. 'done.flag') or parado then
    if parcial ~= '' then
      finalizar(parcial)
    else
      local cru = read_file(DIR .. 'out.txt') or ''
      add('claude', '(nao consegui ler a resposta formatada, saida crua abaixo)'
          .. string.char(10) .. cru)
      busy      = false
      nova      = false
      status    = 'pronto'
      atividade = nil
      os.remove(DIR .. 'done.flag')
    end
    return
  end

  if reaper.time_precise() - started > TIMEOUT then
    add('erro', 'passou de ' .. TIMEOUT .. 's sem resposta. Veja ' .. DIR .. 'out.txt')
    busy   = false
    status = 'timeout'
  end
end

------------------------------------------------------------------ janela

local primeiro_frame = true

local function desenhar()
  if dock and reaper.ImGui_SetNextWindowDockID then
    reaper.ImGui_SetNextWindowDockID(ctx, -1)
  end
  reaper.ImGui_SetNextWindowSize(ctx, 520, 460, COND_FIRST)

  -- Piso de tamanho, aplicado em TODO frame. O ImGui guarda o tamanho da
  -- janela entre sessoes, e um arrasto sem querer na borda deixou ela com
  -- altura de poucos pixels: so a barra de titulo e uma listra, sem caixa de
  -- texto, parecendo quebrada mesmo fechando e abrindo. Com o piso ela nunca
  -- mais fica menor que isso, e acima disso o tamanho dele e respeitado.
  if reaper.ImGui_SetNextWindowSizeConstraints then
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, 380, 240, 4000, 4000)
  end

  -- E nasce sempre desenrolada, caso a setinha do titulo tenha sido clicada.
  -- So no primeiro frame de cada execucao: durante o uso ele ainda pode
  -- enrolar a janela na mao se quiser.
  if primeiro_frame then
    if reaper.ImGui_SetNextWindowCollapsed then
      reaper.ImGui_SetNextWindowCollapsed(ctx, false, COND_SEMPRE)
    end
    primeiro_frame = false
  end

  local visible, open = reaper.ImGui_Begin(ctx, 'Claude REAPER', true)
  if not visible then return open end

  -- barra de cima
  local chg
  chg, dock = reaper.ImGui_Checkbox(ctx, 'Dock', dock)
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, 'Nova conversa') then
    nova = true
    log  = {}
    add('info', 'conversa zerada')
  end
  reaper.ImGui_SameLine(ctx)
  if busy then
    local pontos = string.rep('.', (math.floor(reaper.time_precise() * 2) % 4))
    local seg = math.floor(reaper.time_precise() - started)
    -- a atividade (ferramenta) manda no texto; sem ela, mostra a fase
    local oque = atividade or status
    reaper.ImGui_Text(ctx, oque .. ' ' .. seg .. 's' .. pontos)
  else
    local qual = MODELO or motor.modelo_rapido
    if not qual or qual == '' then qual = 'padrao' end
    reaper.ImGui_Text(ctx, status .. '  |  ' .. motor.nome .. ', ' .. qual ..
                           ', "!" usa o forte')
  end

  reaper.ImGui_Separator(ctx)

  -- caixa de escrever: campo NATIVO, sem EnterReturnsTrue.
  -- Com aquela flag o Enter 'validava' o campo e o ImGui tirava o foco dele,
  -- entao depois do Shift+Enter nao dava pra continuar digitando.
  -- Nativo, o campo sempre insere a quebra e nunca perde o foco.
  local rv
  -- o ImGui guarda o texto num buffer interno enquanto o campo esta em edicao,
  -- e ignora quando eu zero a variavel por fora. Trocar o ID recria o widget,
  -- e e isso que de fato limpa a caixa depois do envio.
  if focar and reaper.ImGui_SetKeyboardFocusHere then
    reaper.ImGui_SetKeyboardFocusHere(ctx)
    focar = false
  end
  rv, input = reaper.ImGui_InputTextMultiline(ctx, '##entrada' .. geracao, input, -1, 70)

  -- Enter envia, Shift+Enter so quebra linha. A quebra que o campo acabou de
  -- inserir sai no trim do envio, entao nao vai lixo no fim do texto.
  local manda = false
  if KEY_ENTER ~= 0 and reaper.ImGui_IsKeyPressed(ctx, KEY_ENTER) then
    local mods = reaper.ImGui_GetKeyMods(ctx)
    local com_shift = MOD_SHIFT ~= 0 and (mods & MOD_SHIFT) ~= 0
    if not com_shift then manda = true end
  end
  if reaper.ImGui_Button(ctx, busy and 'aguarde...' or 'Enviar  (Enter, Shift+Enter quebra linha)') then manda = true end

  if manda and not busy then
    local p = input:gsub('^%s+', ''):gsub('%s+$', '')
    if p ~= '' then
      enviar(p)
      input   = ''
      geracao = geracao + 1
      focar   = true
    end
  end

  reaper.ImGui_Separator(ctx)

  -- historico em caixa somente-leitura: da pra selecionar e copiar com Ctrl+C,
  -- o que nao era possivel quando era texto desenhado na tela.
  -- O texto vai quebrado na largura da janela, senao a caixa rola pro lado e
  -- so da pra ler esticando o REAPER inteiro.
  local largura = 420
  if reaper.ImGui_GetContentRegionAvail then
    local disp = reaper.ImGui_GetContentRegionAvail(ctx)
    -- desconta a barra de rolagem e o respiro interno da caixa
    if disp then largura = disp - 28 end
  end
  if largura < 120 then largura = 120 end
  reaper.ImGui_InputTextMultiline(ctx, '##historico',
                                  quebrar(ctx, historico_txt(), largura),
                                  -1, -1, FLAGS_LEITURA)

  reaper.ImGui_End(ctx)
  return open
end

local function loop()
  checar_resposta()
  local ok, open = pcall(desenhar)
  if not ok then
    reaper.ShowConsoleMsg('Claude REAPER: ' .. tostring(open) .. '\n')
    return
  end
  if open then reaper.defer(loop) end
end

add('info', bridge_vivo() and 'pronto, bridge rodando' or 'pronto, subindo o bridge')
reaper.defer(loop)
