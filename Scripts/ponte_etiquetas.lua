-- Ponte de etiquetas: faz o que o REAPER MCP nao expoe
--
-- O MCP controla faixa, item, FX, marcador e o tempo do projeto inteiro, mas
-- NAO cria saida de hardware nem ponto de mudanca de tempo no meio da musica.
-- Esta action faz a ponte usando o que o MCP JA consegue: escrever texto. O
-- Claude poe uma etiqueta no nome, dispara esta action, e ela cria a coisa de
-- verdade e limpa a etiqueta.
--
-- A etiqueta sumir E o recibo de sucesso. Se continuar la, nao deu.
--
-- 1) SAIDA DE HARDWARE: etiqueta no fim do NOME DA FAIXA
--
--      MON 2 [out3]          saida MONO no canal 3
--      MON 1 [out1-2]        saida ESTEREO nos canais 1 e 2
--      RETORNO [out5-6]      saida ESTEREO nos canais 5 e 6
--
-- 2) MUDANCA DE TEMPO OU DE COMPASSO: etiqueta no NOME DE UM MARCADOR
--
--      [bpm:95]              95 bpm dali em diante
--      [bpm:95 7/8]          95 bpm e compasso 7/8 dali em diante
--      [ts:7/8]              so o compasso, mantem o tempo que estava valendo
--      [bpm:95 lin]          rampa: acelera ou desacelera ate o ponto seguinte
--
--    O ponto cai no beat MAIS PROXIMO do marcador, para nao nascer torto no
--    meio do compasso. Se o marcador tiver texto antes da etiqueta, como
--    "REFRAO [bpm:95]", o marcador continua existindo com o nome limpo. Se o
--    nome for so a etiqueta, o marcador e apagado depois de virar ponto.
--
-- POR QUE TUDO RODA DENTRO DE pcall: quando este script estoura um erro de Lua
-- tendo sido disparado pelo MCP (run_action_by_name), o erro derruba o BRIDGE
-- junto, e o REAPER fica mudo para todas as ferramentas ate alguem reabrir a
-- janelinha. Ja aconteceu. Com pcall o erro vira texto em ponte_erro.log, que
-- da para ler de fora do REAPER, e o bridge continua vivo.

local CANAL_MONO = 1024     -- flag do REAPER em I_DSTCHAN: soma 1024 para mono
local CATEGORIA_HWOUT = 1   -- categoria 1 = hardware outputs
local LIMITE = 20000        -- trava: loop infinito aqui congelaria o REAPER
local NL = string.char(10)
local LOG = reaper.GetResourcePath() .. '/Scripts/claude_console/ponte_erro.log'
local PRESETS = reaper.GetResourcePath() .. '/Scripts/claude_console/render_presets.ini'

local DEBUG = reaper.GetResourcePath() .. '/Scripts/claude_console/ponte_debug.log'
local VERSAO = 'v4-qn'

local criadas = 0
local pontos = 0
local renders = 0
local erros = {}
local diag = {'versao: ' .. VERSAO}

------------------------------------------------------------------------------
-- 1) Saidas de hardware, pelo nome da faixa
------------------------------------------------------------------------------

local function saidas_de_hardware()
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, nome = reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
    local tag = nome:match('%[[Oo][Uu][Tt]([%d%-]+)%]')

    if tag then
      local primeiro, ultimo = tag:match('^(%d+)%-(%d+)$')
      local canal, mono

      if primeiro then
        canal = tonumber(primeiro) - 1        -- I_DSTCHAN e 0-based
        mono = false
        if tonumber(ultimo) ~= tonumber(primeiro) + 1 then
          erros[#erros + 1] = nome .. ': par estereo tem que ser seguido, ex [out1-2]'
          canal = nil
        end
      else
        canal = tonumber(tag) - 1
        mono = true
      end

      if canal and canal >= 0 then
        local idx = reaper.CreateTrackSend(tr, nil)   -- nil = saida de hardware
        if idx and idx >= 0 then
          local valor = canal
          if mono then valor = canal + CANAL_MONO end
          reaper.SetTrackSendInfo_Value(tr, CATEGORIA_HWOUT, idx, 'I_DSTCHAN', valor)

          -- tira a etiqueta: e isso que sinaliza sucesso para quem conferir
          local limpo = nome:gsub('%s*%[[Oo][Uu][Tt][%d%-]+%]', '')
          limpo = limpo:gsub('%s+$', '')
          reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', limpo, true)
          criadas = criadas + 1
        else
          erros[#erros + 1] = nome .. ': o REAPER recusou criar a saida'
        end
      elseif canal and canal < 0 then
        erros[#erros + 1] = nome .. ': canal tem que comecar em 1'
      end
    end
  end
end

------------------------------------------------------------------------------
-- 2) Mudanca de tempo e de compasso, pelo nome do marcador
------------------------------------------------------------------------------

-- Devolve bpm, numerador, denominador, linear, nome_sem_etiqueta.
-- bpm 0 quer dizer "mantem o tempo vigente" (caso do [ts:n/d]).
local function ler_etiqueta(nome)
  local corpo = nome:match('%[[Bb][Pp][Mm]:([^%]]+)%]')
  if corpo then
    local bpm = tonumber(corpo:match('([%d%.]+)'))
    if not bpm or bpm <= 0 then return nil end
    local n, d = corpo:match('(%d+)/(%d+)')
    local lin = corpo:lower():find('lin', 1, true) ~= nil
    local limpo = nome:gsub('%s*%[[Bb][Pp][Mm]:[^%]]+%]', ''):gsub('%s+$', '')
    return bpm, tonumber(n), tonumber(d), lin, limpo
  end

  local n, d = nome:match('%[[Tt][Ss]:(%d+)/(%d+)%]')
  if n then
    local limpo = nome:gsub('%s*%[[Tt][Ss]:%d+/%d+%]', ''):gsub('%s+$', '')
    return 0, tonumber(n), tonumber(d), false, limpo
  end

  return nil
end

local function tempos_pelos_marcadores()
  -- Colhe TODOS os alvos antes de mexer em qualquer coisa. Criar um ponto de
  -- tempo move os marcadores seguintes no relogio, porque eles ficam presos ao
  -- compasso, entao a posicao em segundos envelhece na hora. O beat nao
  -- envelhece, e e ele que vai ser guardado.
  local alvos = {}
  local idx = 0
  while idx < LIMITE do
    local ok, isrgn, pos, _, nome, num_marcador = reaper.EnumProjectMarkers(idx)
    if not ok or ok == 0 then break end

    if not isrgn and nome then
      local bpm, n, d, lin, limpo = ler_etiqueta(nome)
      if bpm then
        -- Guarda a SEMINIMA (quarter note) arredondada, nao o segundo nem o
        -- par compasso/beat. Duas razoes:
        --   1. timeToQN e QNToTime tem UM retorno cada, entao nao tem como
        --      errar a ordem. Com TimeMap2_timeToBeats, que devolve cinco
        --      valores, o ponto nasceu um beat antes do pedido.
        --   2. a seminima nao envelhece quando um ponto anterior deste mesmo
        --      disparo muda o relogio: ela continua a mesma, so muda em que
        --      segundo ela cai, e isso e recalculado na hora de aplicar.
        local qn = reaper.TimeMap2_timeToQN(0, pos) or 0
        local qn_redonda = math.floor(qn + 0.5)
        if qn_redonda < 0 then qn_redonda = 0 end
        diag[#diag + 1] = string.format('colhido %s: pos=%.4f qn=%.4f qn_redonda=%d',
                                        nome, pos, qn, qn_redonda)
        alvos[#alvos + 1] = {
          bpm = bpm, n = n, d = d, lin = lin, limpo = limpo,
          nome = nome, marcador = num_marcador,
          qn = qn_redonda, pos = pos,
        }
      elseif nome:find('%[[Bb][Pp][Mm]:') or nome:find('%[[Tt][Ss]:') then
        erros[#erros + 1] = nome .. ': etiqueta de tempo nao entendida'
      end
    end

    idx = idx + 1
  end

  -- Cria os pontos de tempo
  for _, a in ipairs(alvos) do
    -- O segundo da seminima alvo e calculado AGORA, com o mapa de tempo que os
    -- pontos anteriores deste mesmo disparo deixaram.
    local pos_alvo = reaper.TimeMap2_QNToTime(0, a.qn) or a.pos
    diag[#diag + 1] = string.format('aplicando %s: qn=%d pos_alvo=%.4f bpm=%s',
                                    a.nome, a.qn, pos_alvo, tostring(a.bpm))
    local tsn, tsd, tempo_vigente = reaper.TimeMap_GetTimeSigAtTime(0, pos_alvo)
    local bpm = a.bpm
    if bpm == 0 then bpm = tempo_vigente end
    local n = a.n or tsn
    local d = a.d or tsd

    if bpm and bpm > 0 and n and d then
      local feito = reaper.SetTempoTimeSigMarker(0, -1, pos_alvo, -1, -1,
                                                 bpm, n, d, a.lin and true or false)
      if feito then
        pontos = pontos + 1
        a.aplicado = true
      else
        erros[#erros + 1] = a.nome .. ': o REAPER recusou criar o ponto de tempo'
      end
    else
      erros[#erros + 1] = a.nome .. ': nao deu para descobrir tempo ou compasso vigente'
    end
  end

  -- Limpa as etiquetas dos marcadores que viraram ponto. A posicao e relida
  -- aqui, porque os pontos recem criados podem ter movido o marcador.
  for _, a in ipairs(alvos) do
    if a.aplicado then
      if a.limpo == '' then
        reaper.DeleteProjectMarker(0, a.marcador, false)
      else
        local j = 0
        while j < LIMITE do
          -- Enum3 tambem devolve a cor, para o marcador nao perde-la na
          -- renomeacao. E SetProjectMarker3 leva o projeto como 1o argumento;
          -- o SetProjectMarker sem numero NAO leva, e passar proj nele desloca
          -- tudo uma casa: "bad argument #3 (number expected, got boolean)".
          local ok, isrgn, pos, fim, _, num_marcador, cor =
            reaper.EnumProjectMarkers3(0, j)
          if not ok or ok == 0 then break end
          if not isrgn and num_marcador == a.marcador then
            reaper.SetProjectMarker3(0, a.marcador, false, pos, fim, a.limpo, cor or 0)
            break
          end
          j = j + 1
        end
      end
    end
  end
end

------------------------------------------------------------------------------
-- 3) Render: guardar e aplicar presets, pelo nome do marcador
------------------------------------------------------------------------------

-- O MCP renderiza, mas nao escolhe o FORMATO: profundidade, taxa, MP3 ou WAV,
-- master ou stems, tudo isso vive nas configuracoes do projeto. E o formato em
-- si e um blob que o REAPER guarda em base64 (para WAV, "evaw" mais a
-- profundidade em bits; para MP3, a configuracao do LAME). Inventar esse blob
-- na mao da arquivo corrompido, entao a ponte faz o contrario: CAPTURA o que
-- esta configurado na janela Render to File e guarda com um nome.
--
--   [render:capturar mp3-320]   guarda a configuracao atual com esse nome
--   [render:mp3-320]            aplica a configuracao guardada
--
-- Depois de aplicar, quem renderiza e o MCP (render_project), que ja recebe o
-- caminho de saida no proprio comando.

local CAMPOS_NUM = {
  'RENDER_SRATE', 'RENDER_CHANNELS', 'RENDER_SETTINGS',
  'RENDER_BOUNDSFLAG', 'RENDER_TAILFLAG', 'RENDER_TAILMS',
}

local function ler_presets()
  local t = {}
  local fh = io.open(PRESETS, 'rb')
  if not fh then return t end
  local atual = nil
  for linha in fh:lines() do
    linha = linha:gsub('%s+$', '')
    local nome = linha:match('^%[(.+)%]$')
    if nome then
      atual = nome:lower()
      t[atual] = {}
    elseif atual then
      local k, v = linha:match('^(%w+)=(.*)$')
      if k then t[atual][k] = v end
    end
  end
  fh:close()
  return t
end

local function gravar_presets(t)
  local fh = io.open(PRESETS, 'wb')
  if not fh then return false end
  fh:write('; Presets de render capturados da janela Render to File.' .. NL)
  fh:write('; Aplique criando um marcador chamado [render:<nome>] e rodando a ponte.' .. NL)
  for nome, campos in pairs(t) do
    fh:write(NL .. '[' .. nome .. ']' .. NL)
    fh:write('FORMAT=' .. tostring(campos.FORMAT or '') .. NL)
    for _, c in ipairs(CAMPOS_NUM) do
      fh:write(c .. '=' .. tostring(campos[c] or '') .. NL)
    end
  end
  fh:close()
  return true
end

local function capturar_preset(nome)
  local ok, fmt = reaper.GetSetProjectInfo_String(0, 'RENDER_FORMAT', '', false)
  if not ok or not fmt or fmt == '' then
    return false, 'nao consegui ler o formato de render do projeto'
  end
  local campos = { FORMAT = fmt }
  for _, c in ipairs(CAMPOS_NUM) do
    campos[c] = tostring(reaper.GetSetProjectInfo(0, c, 0, false))
  end
  local t = ler_presets()
  t[nome:lower()] = campos
  if not gravar_presets(t) then return false, 'nao consegui gravar ' .. PRESETS end
  return true
end

local function aplicar_preset(nome)
  local campos = ler_presets()[nome:lower()]
  if not campos then
    return false, 'preset "' .. nome .. '" nao existe em render_presets.ini'
  end
  if campos.FORMAT and campos.FORMAT ~= '' then
    reaper.GetSetProjectInfo_String(0, 'RENDER_FORMAT', campos.FORMAT, true)
  end
  for _, c in ipairs(CAMPOS_NUM) do
    local v = tonumber(campos[c])
    if v then reaper.GetSetProjectInfo(0, c, v, true) end
  end
  return true
end

-- base64 na mao: o Lua do REAPER nao traz um, e o blob do formato e base64
local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local function base64(dados)
  local saida = {}
  for i = 1, #dados, 3 do
    local a, b, c = dados:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local c1 = math.floor(n / 262144) % 64
    local c2 = math.floor(n / 4096) % 64
    local c3 = math.floor(n / 64) % 64
    local c4 = n % 64
    saida[#saida + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
      .. (b and B64:sub(c3 + 1, c3 + 1) or '=')
      .. (c and B64:sub(c4 + 1, c4 + 1) or '=')
  end
  return table.concat(saida)
end

-- O blob do WAV e curto e legivel: "evaw" (wave ao contrario), a profundidade
-- em bits, e duas flags. Conferido decodificando o que o REAPER gravou.
-- Por isso WAV a ponte MONTA na hora, em qualquer profundidade, sem precisar
-- de preset nenhum. MP3 e os outros tem configuracao de codec e vem de preset.
local function blob_wav(bits)
  return base64('evaw' .. string.char(bits) .. string.char(0) .. string.char(1))
end

-- aceita 48, 48000, 44.1, 44100 e devolve sempre em Hz
local function normalizar_srate(n)
  if not n then return nil end
  if n < 500 then return math.floor(n * 1000 + 0.5) end
  return math.floor(n + 0.5)
end

-- Monta a configuracao de render a partir do que foi pedido, em palavras:
--   wav 24 48            WAV 24 bits, 48 kHz
--   wav 16 44.1 stems    WAV 16 bits, 44,1 kHz, saindo em stems
--   mp3-320              aplica o preset guardado com esse nome
--   mp3-320 48 stems     o preset, mas em 48 kHz e em stems
-- A ordem das palavras nao importa, e o que nao for dito fica como esta.
local function montar_render(corpo)
  local palavras = {}
  for p in corpo:gmatch('%S+') do palavras[#palavras + 1] = p end

  local tipo = (palavras[1] or ''):lower()
  local bits, srate, stems, canais

  for i = 2, #palavras do
    local p = palavras[i]:lower()
    local n = tonumber(p)
    if p == 'stems' then stems = true
    elseif p == 'master' then stems = false
    elseif p == 'mono' then canais = 1
    elseif p == 'stereo' or p == 'estereo' then canais = 2
    elseif n then
      -- 8, 16, 24 e 32 so fazem sentido como profundidade; o resto e taxa
      if n == 8 or n == 16 or n == 24 or n == 32 then bits = n else srate = normalizar_srate(n) end
    end
  end

  if tipo == 'wav' then
    -- Sem dizer profundidade nem taxa, sai 24 bits e 48 kHz, que e o padrao
    -- de trabalho mais comum. Os numeros na etiqueta existem para quando voce
    -- quiser outra coisa (16 bits e 44,1 kHz para CD, por exemplo).
    reaper.GetSetProjectInfo_String(0, 'RENDER_FORMAT', blob_wav(bits or 24), true)
    if not srate then srate = 48000 end
  else
    local ok, err = aplicar_preset(tipo)
    if not ok then return false, err end
  end

  if srate  then reaper.GetSetProjectInfo(0, 'RENDER_SRATE', srate, true) end
  if canais then reaper.GetSetProjectInfo(0, 'RENDER_CHANNELS', canais, true) end

  if stems == true then
    -- o codigo de "master mix and stems" nao da pra inventar: ele vem de uma
    -- captura feita com essa opcao marcada na janela de render
    local p = ler_presets()['stems']
    local v = p and tonumber(p.RENDER_SETTINGS)
    if not v then
      return false, 'ainda nao sei o codigo de stems: marque "Master mix and stems" na janela de render, clique Save settings e rode [render:capturar stems]'
    end
    reaper.GetSetProjectInfo(0, 'RENDER_SETTINGS', v, true)
  elseif stems == false then
    reaper.GetSetProjectInfo(0, 'RENDER_SETTINGS', 0, true)
  end

  return true
end

local function render_pelos_marcadores()
  local alvos = {}
  local idx = 0
  while idx < LIMITE do
    local ok, isrgn, _, _, nome, num_marcador = reaper.EnumProjectMarkers(idx)
    if not ok or ok == 0 then break end
    if not isrgn and nome then
      local corpo = nome:match('%[[Rr][Ee][Nn][Dd][Ee][Rr]:([^%]]+)%]')
      if corpo then
        alvos[#alvos + 1] = { corpo = corpo, marcador = num_marcador, nome = nome }
      end
    end
    idx = idx + 1
  end

  for _, a in ipairs(alvos) do
    local primeira, resto = a.corpo:match('^%s*(%S+)%s*(.-)%s*$')
    local ok, err
    if primeira and primeira:lower() == 'capturar' then
      if not resto or resto == '' then
        ok, err = false, 'faltou o nome: use [render:capturar <nome>]'
      else
        ok, err = capturar_preset(resto)
      end
    else
      ok, err = montar_render(a.corpo)
    end

    if ok then
      renders = renders + 1
      -- o marcador era so o recado, some depois de cumprido
      reaper.DeleteProjectMarker(0, a.marcador, false)
    else
      erros[#erros + 1] = a.nome .. ': ' .. tostring(err)
    end
  end
end

------------------------------------------------------------------------------
-- Execucao protegida
------------------------------------------------------------------------------

reaper.Undo_BeginBlock()

local ok1, err1 = pcall(saidas_de_hardware)
local ok2, err2 = pcall(tempos_pelos_marcadores)
local ok3, err3 = pcall(render_pelos_marcadores)

if pontos > 0 then reaper.UpdateTimeline() end

reaper.Undo_EndBlock('MCP: ponte de etiquetas (saidas de hardware e tempo)', -1)

if not ok1 then erros[#erros + 1] = 'ERRO DE SCRIPT em saidas: ' .. tostring(err1) end
if not ok2 then erros[#erros + 1] = 'ERRO DE SCRIPT em tempo: ' .. tostring(err2) end
if not ok3 then erros[#erros + 1] = 'ERRO DE SCRIPT em render: ' .. tostring(err3) end

-- Diario de bordo, sempre. Serve para provar qual VERSAO do arquivo o REAPER
-- acabou de rodar, e com que numeros. Sem isso nao da para distinguir "o
-- calculo esta errado" de "o REAPER rodou a versao velha do script".
do
  local f = io.open(DEBUG, 'w')
  if f then
    for _, l in ipairs(diag) do f:write(l .. NL) end
    f:close()
  end
end

-- Em uso normal NAO abre janela nenhuma e NAO deixa log: o recibo de sucesso e
-- a etiqueta sumir. So fala quando da errado, que e quando interessa.
if #erros > 0 then
  local f = io.open(LOG, 'w')
  if f then
    for _, e in ipairs(erros) do f:write('ponte ERRO: ' .. e .. NL) end
    f:close()
  end
  for _, e in ipairs(erros) do
    reaper.ShowConsoleMsg('ponte ERRO: ' .. e .. NL)
  end
else
  os.remove(LOG)   -- sem erro agora = sem log velho enganando depois
end
