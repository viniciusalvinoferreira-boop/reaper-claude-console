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

local DEBUG = reaper.GetResourcePath() .. '/Scripts/claude_console/ponte_debug.log'
local VERSAO = 'v4-qn'

local criadas = 0
local pontos = 0
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
-- Execucao protegida
------------------------------------------------------------------------------

reaper.Undo_BeginBlock()

local ok1, err1 = pcall(saidas_de_hardware)
local ok2, err2 = pcall(tempos_pelos_marcadores)

if pontos > 0 then reaper.UpdateTimeline() end

reaper.Undo_EndBlock('MCP: ponte de etiquetas (saidas de hardware e tempo)', -1)

if not ok1 then erros[#erros + 1] = 'ERRO DE SCRIPT em saidas: ' .. tostring(err1) end
if not ok2 then erros[#erros + 1] = 'ERRO DE SCRIPT em tempo: ' .. tostring(err2) end

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
