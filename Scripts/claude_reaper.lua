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
local CLAUDE   = (os.getenv('APPDATA') or '') .. BS .. 'npm' .. BS .. 'claude.cmd'
local DIR      = reaper.GetResourcePath() .. '/Scripts/claude_console/'
local DIR_WIN  = DIR:gsub('/', BS)
local TIMEOUT  = 1800  -- 30 min. so existe pra nao ficar preso pra sempre se algo morrer
local MODELO   = ''    -- vazio = padrao da conta. 'haiku' responde bem mais rapido

------------------------------------------------------------------ checagens

if not reaper.ImGui_CreateContext then
  reaper.MB('ReaImGui nao encontrado.\n\nInstale pelo ReaPack:\nExtensions > ReaPack > Browse packages > "ReaImGui".',
            'Claude REAPER', 0)
  return
end

local f = io.open(CLAUDE, 'r')
if f then f:close() else
  reaper.MB('CLI do Claude nao encontrado em:\n' .. CLAUDE ..
            '\n\nAjuste a variavel CLAUDE no topo do script.', 'Claude REAPER', 0)
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
  -- esse ID e o hash do caminho Scripts/reaper_mcp_bridge.lua. Se o seu bridge
  -- estiver em outro lugar, troque pelo seu Command ID. Se nao resolver, o
  -- fallback abaixo carrega o arquivo direto e funciona do mesmo jeito.
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
local last_size   = -1    -- pra saber quando o out.txt parou de crescer
local last_change = 0
local dock     = false
local geracao  = 0        -- muda o ID do campo pra forcar o ImGui a largar o buffer
local focar    = false    -- devolve o cursor pra caixa no frame seguinte
local atividade = nil     -- ferramenta que ele esta chamando agora

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
  return table.concat(partes, string.char(10) .. string.char(10))
end

local function add(papel, texto)
  log[#log + 1] = { papel = papel, texto = texto }
end

------------------------------------------------------------------ envio

local function enviar(prompt)
  if busy or prompt == '' then return end

  os.remove(DIR .. 'done.flag')
  os.remove(DIR .. 'out.txt')

  if not write_file(DIR .. 'prompt.txt', prompt) then
    add('erro', 'nao consegui escrever em ' .. DIR)
    return
  end

  local cont = nova and '' or ' --continue'
  local modelo = (MODELO ~= '' ) and (' --model ' .. MODELO) or ''
  local bat = table.concat({
    '@echo off',
    'chcp 65001 >nul',
    -- sem a barra final: no cmd, barra antes de aspa escapa a aspa
    'cd /d "' .. DIR_WIN:sub(1, -2) .. '"',
    -- 'call' e obrigatorio: sem ele, chamar um .cmd de dentro de um .bat
    -- entrega o controle e nunca volta, e a done.flag nao seria escrita
    -- --strict-mcp-config + --mcp-config: carrega SO o servidor do REAPER.
    -- sem isso, cada chamada sobe todos os MCP da conta (Gmail, Drive, Docs,
    -- Calendar, Playwright via npx) e perde dezenas de segundos antes de comecar.
    'call "' .. CLAUDE .. '" -p --output-format stream-json --verbose --mcp-config "mcp-reaper.json" --strict-mcp-config --allowedTools "mcp__reaper" "Skill"' .. modelo .. cont .. ' < "prompt.txt" > "out.txt" 2>&1',
    'echo done> "done.flag"',
  }, '\r\n') .. '\r\n'

  if not write_file(DIR .. 'run.bat', bat) then
    add('erro', 'nao consegui escrever o run.bat')
    return
  end

  add('voce', prompt)
  last_size   = -1
  last_change = reaper.time_precise()
  busy    = true
  started = reaper.time_precise()
  status  = 'pensando'
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
local function extrai_result(txt)
  local marca = '"result":"'
  -- a ULTIMA ocorrencia: o evento final e a ultima linha do stream,
  -- e pegar a primeira poderia ler o campo de outro evento
  local i, pos = nil, 1
  while true do
    local k = txt:find(marca, pos, true)
    if not k then break end
    i, pos = k, k + 1
  end
  if not i then return nil end
  local j = i + #marca
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

local function checar_resposta()
  if not busy then return end

  local txt = read_file(DIR .. 'out.txt') or ''

  -- mostra o que ele esta fazendo agora, em vez de so um contador correndo
  local ult = nil
  for nome in txt:gmatch('"name":"mcp__reaper__([%a_]+)"') do ult = nome end
  atividade = ult

  -- fim exato: o evento final traz o texto da resposta
  local final = extrai_result(txt)
  if final then
    final = final:gsub('^%s+', ''):gsub('%s+$', '')
    if final == '' then final = '(resposta vazia)' end
    add('claude', final)
    busy      = false
    nova      = false
    status    = 'pronto'
    atividade = nil
    os.remove(DIR .. 'done.flag')
    return
  end

  -- rede de seguranca: se o processo terminou mas nao achei o evento final,
  -- mostro a saida crua em vez de deixar a janela pendurada
  local sz = #txt
  if sz ~= last_size then
    last_size   = sz
    last_change = reaper.time_precise()
  end
  local parado = sz > 0 and (reaper.time_precise() - last_change) > 10
  if file_exists(DIR .. 'done.flag') or parado then
    add('claude', '(nao consegui ler a resposta formatada, saida crua abaixo)'
        .. string.char(10) .. txt)
    busy      = false
    nova      = false
    status    = 'pronto'
    atividade = nil
    os.remove(DIR .. 'done.flag')
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
    local oque = atividade and (' ' .. atividade) or ''
    reaper.ImGui_Text(ctx, 'pensando ' .. seg .. 's' .. oque .. pontos)
  else
    reaper.ImGui_Text(ctx, status)
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
  -- o que nao era possivel quando era texto desenhado na tela
  reaper.ImGui_InputTextMultiline(ctx, '##historico', historico_txt(), -1, -1, FLAGS_LEITURA)

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
