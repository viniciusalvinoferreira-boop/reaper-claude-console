# Claude no REAPER

Uma janelinha dentro do REAPER para você pedir as coisas em português e elas acontecerem no
projeto, sem sair do REAPER e sem ficar indo e voltando do terminal.

```
você: monta o setup de voz com dois fones
      cria 4 compassos de um groove em 95 bpm com virada no fim
      quantiza só o bumbo e a caixa, deixa o chimbal solto
      95 bpm a partir daqui
```

Funciona pela sua assinatura do Claude Code. **Não usa chave de API nem cobra por uso.**

## O que tem aqui

| Arquivo | O que faz |
|---|---|
| `Scripts/claude_reaper.lua` | A janelinha. Janela ImGui dentro do REAPER que chama o Claude Code em modo headless, mostra a resposta e sobe o servidor MCP sozinha quando precisa. |
| `Scripts/ponte_etiquetas.lua` | A ponte. Faz o que o MCP não expõe: **saída de hardware** e **mudança de tempo e de compasso**, lendo etiquetas que o Claude escreve em nome de faixa e de marcador. |
| `Scripts/claude_console/CLAUDE.md` | As regras, lidas a cada mensagem. É aqui que você ensina as suas manias. Mudar comportamento é editar texto, não código. |
| `Scripts/claude_console/.claude/skills/setup-voz/` | Exemplo de skill: um checklist completo de setup de gravação de voz. |

## Requisitos

- **REAPER 7.x**
- **[ReaImGui](https://github.com/cfillion/reaimgui)**, via ReaPack
- **[SWS](https://www.sws-extension.org/)**, se quiser que a janelinha abra sozinha com o REAPER
- **[uv](https://docs.astral.sh/uv/)**, para rodar o servidor MCP
- **[Claude Code](https://claude.com/claude-code)** instalado e autenticado
- **[twelvetake-reaper-mcp](https://pypi.org/project/twelvetake-reaper-mcp/)**, o servidor MCP que
  conversa com o REAPER. Ele instala um script de bridge dentro do REAPER.

## Instalação

1. **Instale o servidor MCP e o bridge.** Siga as instruções do `twelvetake-reaper-mcp`. No fim
   você deve ter um `reaper_mcp_bridge.lua` na sua pasta `Scripts` do REAPER, rodando.

2. **Copie os arquivos deste repositório** para a sua pasta de recursos do REAPER
   (`Options` → `Show REAPER resource path`), mantendo a estrutura:

       Scripts/claude_reaper.lua
       Scripts/ponte_etiquetas.lua
       Scripts/claude_console/CLAUDE.md
       Scripts/claude_console/.claude/skills/setup-voz/SKILL.md

3. **Crie o `mcp-reaper.json`** a partir do exemplo, em `Scripts/claude_console/`. Se o `uvx` não
   estiver no PATH que o REAPER enxerga, use o caminho absoluto dele.

   Esse arquivo é o que mais importa para a velocidade: a janelinha roda o Claude Code com
   `--mcp-config` e `--strict-mcp-config`, então **só o servidor do REAPER sobe**. Sem isso, cada
   mensagem carrega todos os servidores MCP da sua conta e a resposta demora uma eternidade.

4. **Registre os dois scripts como actions**: janela `Actions` → `New action` → `Load ReaScript`.

5. **Pegue o Command ID da ponte**: na lista de actions, botão direito no `ponte_etiquetas.lua` →
   `Copy selected action command ID`. Cole no `CLAUDE.md`, no lugar de `COMMAND_ID_DA_PONTE`.
   Sem isso, saída de hardware e mudança de tempo não funcionam.

6. **Para a janelinha abrir junto com o REAPER** (opcional): copie o Command ID do
   `claude_reaper.lua` e use a action `SWS/S&M: Set global startup action`, que pede o ID colado.

## Como usar

Abra a janelinha pela action. Escreva e aperte **Enter** para enviar; **Shift+Enter** quebra linha.

A janela mostra o que está acontecendo enquanto trabalha, em vez de um contador correndo:

```
pensando → procurando a ferramenta → lendo o projeto →
criando faixa → mexendo nos plugins → lendo o projeto
```

e a resposta vai aparecendo conforme ele escreve.

### Modelo

O padrão é o **Haiku**, porque comando de DAW é curto e objetivo. Para mandar uma mensagem no
modelo forte, comece ela com `!`. O `!` não vai junto no prompt.

Medido nesta configuração, mesmo comando nos dois modelos:

| Comando | Modelo padrão | Haiku |
|---|---|---|
| "quantas faixas tem no projeto" | 8.667 ms | **6.157 ms** |
| "cria uma faixa REAMP GTR com ReaEQ e ReaComp" | 20.233 ms | **11.606 ms** |

Troque o padrão na variável `MODELO`, no topo do script.

### A ponte de etiquetas

O servidor MCP controla faixa, item, FX, marcador e o tempo do projeto, mas não cria saída de
hardware nem mudança de tempo no meio da música. A ponte resolve isso com o único recurso que
sobra: **escrever texto**. O Claude põe a etiqueta no nome, dispara a action, e ela cria a coisa de
verdade e apaga a etiqueta. **A etiqueta sumir é o recibo de sucesso.**

Em nome de **faixa**:

    MON 1 [out1-2]     saída estéreo nos canais 1 e 2
    MON 2 [out3]       saída mono no canal 3

Em nome de **marcador**:

    REFRAO [bpm:95]    95 bpm dali em diante, e o marcador continua existindo
    [bpm:95 7/8]       tempo e fórmula de compasso juntos
    [ts:7/8]           só a fórmula, mantendo o tempo
    [bpm:140 lin]      rampa até o ponto seguinte

Tudo roda dentro de `pcall` e grava erro em `claude_console/ponte_erro.log`, legível de fora do
REAPER. Isso não é frescura: **um erro de Lua num script disparado pelo MCP derruba o bridge
junto**, e aí o REAPER continua aberto mas fica mudo para todas as ferramentas.

## Coisas que custaram caro para descobrir

- **Erro de Lua em script disparado pelo MCP mata o bridge.** O REAPER segue respondendo e tudo dá
  timeout, inclusive leitura. A recuperação é fechar e reabrir a janelinha, que sobe o bridge pelo
  heartbeat. Por isso a ponte roda inteira em `pcall`.
- **Dois clientes MCP no mesmo bridge se atropelam.** Se você mandar comando pela janelinha
  enquanto outro cliente trabalha, os dois tomam timeout. Um de cada vez.
- **`timed out after 5s` não quer dizer que falhou.** Pode ter funcionado. Sempre reler o projeto
  antes de afirmar qualquer coisa, e é isso que o `CLAUDE.md` manda fazer.
- **Mudança de tempo cai no início do compasso**, não onde você pediu: o REAPER alinha sozinho.
- **Marcador está preso ao compasso, não ao segundo.** Mudar o tempo move os marcadores no relógio.
- **Abrir template precisa do prefixo `template:`** no caminho, senão o REAPER abre o arquivo do
  template e um Ctrl+S distraído o sobrescreve.
- **O gargalo não é o REAPER.** Instrumentando evento por evento, o bridge responde em **190 ms**.
  O que pesa é a inicialização da sessão e, principalmente, uma chamada de `ToolSearch` que custa
  **2,4 s** antes de qualquer trabalho, porque o servidor expõe cerca de 190 ferramentas e o
  harness adia a carga delas. Autorizar a ferramenta pelo nome exato em vez do prefixo **não
  evita** isso: foi testado.
- **O processo em si sobe em 127 ms.** Se você for otimizar, não comece pelo boot.
- **Ler o `out.txt` inteiro a cada frame não escala** depois que `--include-partial-messages`
  entra: o arquivo passa a ter um evento por pedaço de texto. A janela lê a partir do ponto onde
  parou e processa só linhas completas.
- **O texto entre uma ferramenta e outra é narração do raciocínio**, e costuma sair em inglês.
  Mostrar isso na tela confunde: o texto parcial é zerado a cada ferramenta nova, então sobra só
  a resposta final.

## Por que as regras ficam em um arquivo de texto

Porque corrigir comportamento vira edição de texto, não programação. Armou uma faixa quando não
devia? Escreve a regra. Fez o trabalho pela metade? Escreve o checklist. O `CLAUDE.md` deste
repositório é um ponto de partida, e a regra número um dele nasceu de um susto real: **faixa nova
nasce desarmada**, para não estourar ganho com as caixas abertas.

## Licença

MIT. Os scripts são independentes do `twelvetake-reaper-mcp` (também MIT), do ReaImGui e do SWS,
cada um com a sua própria licença.
