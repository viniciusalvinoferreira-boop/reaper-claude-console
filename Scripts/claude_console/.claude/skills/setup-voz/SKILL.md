---
name: setup-voz
description: Monta um setup de gravação de voz no REAPER (backing track, voz principal, voz dobra, bus com cadeia de plugins, faixa de reverb só para os fones, cores e duas monitorações com saída de hardware). Use quando pedirem para preparar voz, vocal, gravar voz, montar canal de voz, bus de voz, setup de gravação, fone, monitoração, reverb no fone, ou qualquer pedido de preparar projeto para cantar ou locutar.
---

# Setup de voz no REAPER

Exemplo de skill: um checklist que o console executa até o fim. Adapte os nomes, as cores e a
cadeia ao seu gosto. **Execute até o fim.** Entregar faixas secas, sem plugins e sem cor, não é o
trabalho feito. Se o pedido foi explicitamente só uma parte ("só cria a faixa"), respeite e pare.

## O setup padrão

| Faixa | Cor (r,g,b) | Papel |
|---|---|---|
| `BACKINGTRACK` | 130, 130, 140 | playback, a base |
| `VOZ` | 80, 200, 120 | captação principal |
| `VOZ DOBRA` | 60, 160, 100 | camada de dobra |
| `BUS VOZ` | 70, 130, 220 | tratamento das duas vozes |
| `REVERB MON` | 150, 110, 200 | reverb que só existe nos fones |
| `MON 1` | 230, 150, 60 | fone do operador, saída `[out1-2]` |
| `MON 2` | 230, 150, 60 | fone do cantor, saída `[out3-4]` |

Se o pedido disser o nome da pessoa, use o nome: `MON JOANA`.

## Passo 1. Ler antes de criar

`get_project_summary`. **Reaproveite o que já existe.** Se já tem `BUS VOZ`, use ele em vez de
criar outro. Só crie o que falta.

## Passo 2. Criar as faixas

Para **cada** faixa: `insert_track`, depois `set_track_color`.

Em **toda** faixa criada, sem exceção:

- `arm_track` com `arm: false`
- `set_track_monitor` com `monitor: 0`

**Faça isso sempre, mesmo que pareça desnecessário.** Faixa armada com caixa aberta gera
microfonia e estoura ganho.

## Passo 3. Roteamento

**Tudo chega nas monitorações por send, nada pelo master.** É assim que se controla quanto de cada
coisa vai para cada fone, de forma independente. Master send é tudo ou nada, e não serve.

- `VOZ` e `VOZ DOBRA`: `create_send` para `BUS VOZ`, e `set_track_master_send` **false** nas duas.
- `BUS VOZ`: `set_track_master_send` **false**. A voz não vai para as caixas, para o microfone
  aberto não realimentar.
- `BACKINGTRACK`: `set_track_master_send` **false** também.
- `BUS VOZ` manda `create_send` para `REVERB MON`, `MON 1` e `MON 2`.
- `BACKINGTRACK` manda `create_send` para `MON 1` e `MON 2`.
- `REVERB MON` manda `create_send` para `MON 1` e `MON 2`, com master send **false**.
- `MON 1` e `MON 2`: `set_track_master_send` **false**. Existem só para alimentar uma saída física.

Resultado: cada fone tem a própria mistura, ajustável com `set_send_volume` sem um mexer no outro.

**Consequência esperada:** com tudo fora do master, o master fica sem sinal durante a gravação. Na
hora de mixar ou renderizar, religar os master sends.

## Passo 4. Cadeia de plugins, no BUS e nunca nas faixas de voz

`track_fx_add_by_name` no `BUS VOZ`, nesta ordem. Só os nativos da Cockos, que todo REAPER tem:

1. `ReaEQ` (corte de grave, high pass em 80 Hz)
2. `ReaGate` (respiração e ruído de sala)
3. `ReaXcomp` (sibilância)
4. `ReaComp` (compressão)
5. `ReaEQ` (brilho e presença)
6. `ReaLimit` (rede de proteção, sempre por último)

Troque por plugins melhores se tiver, mas **confirme que eles passam sinal antes de confiar**:
plugin em avaliação expirada carrega sem erro e silencia o áudio.

### O reverb da REVERB MON

Um plugin só nessa faixa, no preset de fábrica. Qualquer reverb serve; `ReaVerbate` já resolve.

**Por que faixa separada e não um reverb no fim do bus:** para dosar quanto de reverb vai para
**cada fone** de forma independente. Quem canta costuma querer bastante, porque ajuda a soltar e a
afinar; quem opera quer pouco, para julgar a voz crua.

Nos dois arranjos a gravação sai seca, porque as faixas de captação gravam o sinal que entra pelo
microfone, antes do bus. O ganho da faixa separada é o controle por fone.

### Parâmetros: faça só o high pass, e só deste jeito

**Não saia sondando parâmetro de plugin.** Varredura de índice é cara: já fez um setup simples
passar de 57 chamadas de ferramenta e vários minutos de espera.

O único ajuste é o high pass do **primeiro** `ReaEQ`, com a ferramenta dedicada, que aceita Hz
direto e resolve numa chamada:

`set_eq_band` com `fx_index: 0`, `bandtype: 0` (hipass), `bandidx: 0`, `paramtype: 0` (frequência),
`value: 80`.

Os outros cinco ficam **nos valores de fábrica**. A estrutura é o seu trabalho, o tempero é de quem
está ouvindo.

## Passo 5. Saídas de hardware

O MCP não tem ferramenta para isso. Use a ponte por etiqueta, e os três passos são um trabalho só:

1. Renomeie: `MON 1 [out1-2]` e `MON 2 [out3-4]`
2. Rode a action da ponte pelo Command ID
3. Releia os nomes. Etiqueta sumiu = criada. Etiqueta ainda lá = não criou, e **diga isso**

Para saída mono use um número só: `[out3]`. Par estéreo tem que ser seguido.

## Passo 6. Conferência obrigatória

Antes de responder, rode `get_all_tracks` e confira item por item:

- [ ] as 7 faixas existem, com os nomes certos
- [ ] o `BUS VOZ` tem os 6 FX na ordem, e a `REVERB MON` tem o reverb
- [ ] nenhuma etiqueta `[outN]` sobrou em nome de faixa
- [ ] nada ficou em solo ou mute

Responda em até 3 linhas, dizendo o que ficou pronto e **o que não deu certo**. Nunca descreva
resultado que você não viu na leitura.
