<div align="center">

```
╭──────────────────────────────────────────────────────────╮
│  hogspot — caçando os disk hogs                          │
╰──────────────────────────────────────────────────────────╯
```

### Spot the disk hogs.

**Descubra onde os GBs do seu disco foram parar — e o que é seguro apagar.**

[![macOS](https://img.shields.io/badge/macOS-suportado-C97B5B?style=flat-square&logo=apple&logoColor=white)](#-requisitos)
[![Linux](https://img.shields.io/badge/Linux-Ubuntu%20%2F%20Debian-C97B5B?style=flat-square&logo=linux&logoColor=white)](#-requisitos)
[![Confirmação](https://img.shields.io/badge/limpeza-s%C3%B3%20com%20confirma%C3%A7%C3%A3o-7BA887?style=flat-square)](#-segurança)
[![Bash](https://img.shields.io/badge/bash-3.2%2B-D8A155?style=flat-square&logo=gnubash&logoColor=white)](#-requisitos)
[![Zero deps](https://img.shields.io/badge/depend%C3%AAncias-nenhuma-7BA887?style=flat-square)](#-requisitos)
[![Licença MIT](https://img.shields.io/badge/licen%C3%A7a-MIT-D8A155?style=flat-square)](LICENSE)

</div>

---

`hogspot` é um script único de shell que varre sua máquina, mostra **onde o espaço
está indo** e — o que ninguém mais faz — **qual comando roda pra recuperar cada GB**,
classificado por risco.

A varredura não apaga nada. No fim, um menu mostra os detalhes de cada item e roda o
comando que você escolher — só depois da sua confirmação.

> **Por que existe:** DaisyDisk te mostra *onde* está. `du -sh *` te mostra *quanto*.
> Nenhum dos dois te diz que aqueles 18 GB são simuladores iOS órfãos que somem com
> um `xcrun simctl delete unavailable`.

---

## ⚡ Uso rápido

```bash
git clone https://github.com/trentas/hogspot.git
cd hogspot
./hogspot.sh
```

Sem instalação, sem daemon, sem dependências. Se quiser deixar no `PATH`:

```bash
sudo install -m 755 hogspot.sh /usr/local/bin/hogspot
hogspot
```

Ele varre a máquina, mostra um resumo do que dá pra limpar e abre um menu: digite
o número de um item pra ver o que é, onde está e o comando que libera o espaço.

**Com pressa?** `./hogspot.sh --quick` pula os scans lentos (varredura de
projetos e arquivos gigantes pelo `$HOME`) e termina em segundos.

---

## 📋 Exemplo de saída

O resumo começa pelo que importa — quanto dá pra liberar e com que risco — e
lista cada oportunidade numerada, agrupada por nível de risco:

```text
━━ Resumo ━━

  Disco (container APFS): 393.7 GB de 460.4 GB em uso (86%) — 66.7 GB livres

  Dá pra liberar      libera   livre depois
    SEGURO            47.3 GB       114.0 GB   regenera sozinho
  + MODERADO          23.9 GB       137.9 GB   custa re-download ou rebuild
  + REVISAR           61.2 GB       199.1 GB   decisão sua: pode haver dado seu
  (estimativas: itens sobrepostos contam uma vez)

━━ O que dá pra limpar ━━

  SEGURO — regenera sozinho (47.3 GB no total)
     1.   18.4 GB  7 simulador(es) iOS indisponível(eis)
     2.    7.3 GB  Homebrew (cleanup -s --prune=all)
     3.    6.8 GB  Cache: com.brave.Browser
     ...

  MODERADO — custa re-download ou rebuild (23.9 GB no total)
     9.   12.7 GB  Simulator runtimes em /Library/Developer/CoreSimulator/Profiles/Runtimes  (manual)
     ...

  REVISAR — decisão sua: pode haver dado seu (61.2 GB no total)
    14.    9.1 GB  Docker (imagens/containers/volumes reclaimable)
     ...

  Fora da conta:
    · --quick: node_modules, builds, worktrees e arquivos >1 GB pelo $HOME não foram varridos

✓ Análise concluída em 41 s.

  Digite números da lista (ex.: 2 ou 1 3 5-7) pra ver detalhes e limpar.
  t roda todos os SEGURO · l mostra a lista · r relatório completo · s salva em arquivo · Enter sai
  Nada roda sem você confirmar.
```

<details>
<summary><b>Ver um item sendo limpo pelo menu</b></summary>

```text
  › 2

  2. Homebrew (cleanup -s --prune=all)  SEGURO  7.3 GB
     regenera sozinho
     onde:     ~/Library/Caches/Homebrew
     comando:  brew cleanup -s --prune=all
     maiores dentro:
        6.9 GB  downloads
      412.0 MB  Cask

  Rodar 1 comando(s) (libera ~7.3 GB)? [s/N] s

  $ brew cleanup -s --prune=all
  ==> This operation has freed approximately 7.3GB of disk space.
  ✓ Homebrew (cleanup -s --prune=all)

  Livre agora (disco): 74.0 GB (+7.3 GB)
```

</details>

Quer o relatório seção por seção (cada cache, o mapa da raiz, o `docker system df`, os
dry-runs do Homebrew)? Rode com `--full`, ou aperte `r` no menu.

---

## 🎛 Opções

| Flag | O que faz |
|---|---|
| *(nenhuma)* | Resumo do que dá pra limpar, seguido do menu |
| `--full` | Mostra o relatório completo, seção por seção, antes do resumo |
| `--top N` | Quantos itens por seção no relatório completo (default: `15`) |
| `--quick` | Pula os scans demorados (projetos — `node_modules`, builds, worktrees — e arquivos gigantes no `$HOME`) |
| `--detail` | Abre a composição interna dos caches de dev, com comando por subpasta |
| `--report ARQUIVO` | Salva o relatório completo (seções + resumo com os comandos) em markdown |
| `--no-menu` | Só imprime, sem menu no fim (o resumo passa a mostrar o comando de cada item) |
| `--no-color` | Sem cores nem spinner (bom pra pipe, CI e logs) |
| `--help`, `-h` | Ajuda |

```bash
./hogspot.sh --detail --top 25
./hogspot.sh --report ~/Downloads/hogspot-$(date +%F).md
./hogspot.sh --quick --full --no-color > relatorio.txt
```

---

## 🔍 O que ele olha

Cada seção só aparece se existir na sua máquina — sem Docker instalado, sem seção de Docker.

| Área | macOS | Linux |
|---|---|---|
| **Visão geral do disco** | Container APFS + todos os volumes (não só `/`) | `/`, `$HOME` e `/boot` separadamente; avisa quando `/boot` passa de 80%; swapfile e reserva do ext4 (com dica de `tune2fs` quando o disco aperta) |
| **Mapa da raiz** | — | O `/` por pasta (abre `/home`, `/var`, `/var/lib` e `/opt`), fechando a conta com o `df`: sem root mostra o que ficou sem medir (e o que o Docker declara); com root, aponta arquivos apagados ainda abertos (`lsof +L1`) |
| **Snapshots locais** | Time Machine (`tmutil`) | ZFS / Timeshift / Btrfs |
| **Home** | Top N pastas, Downloads, Lixeira | idem (respeita `xdg-user-dir`) |
| **Caches do usuário** | `~/Library/Caches` | `~/.cache` (`$XDG_CACHE_HOME`) |
| **Dados de apps** | `~/Library/Application Support` | `~/.local/share` |
| **Apps empacotados** | `~/Library/Containers` | Flatpak (`~/.var/app`) e Snap (`~/snap`) |
| **Sistema** | Logs em `~/Library/Logs` | Cache do apt/dnf/pacman, `apt autoremove` (órfãos e kernels antigos, pelo próprio apt), maiores pacotes instalados, snaps instalados, revisões desativadas e downloads órfãos do snapd, seed da instalação, journal do systemd (avisa quando não tem limite), logs gigantes de `/var/log` um a um, core dumps, apport, caches do root (`/root/.cache`, `/root/go`) |
| **Xcode / iOS** | DerivedData, Archives, DeviceSupport, simuladores indisponíveis, runtimes `unusable`, backups do MobileSync | — |
| **Navegadores** | Chrome: cache HTTP, PWAs, `component_crx_cache` | Chrome, Chromium, Brave, Edge, Vivaldi, Firefox (incl. snap e Flatpak) |
| **Homebrew** | Dry-run conservador **e** agressivo, com o ganho real de cada um; tamanho do Cellar e dependências órfãs | idem, se instalado |
| **Containers** | Docker, OrbStack, Colima, Lima | Docker (incl. `/var/lib/containerd`), Podman |
| **Caches de dev** | `.npm`, `.pnpm-store`, `.yarn`, `.gradle`, `.m2`, `.cargo`, `.rustup`, `.nvm`, `.bun`, `go/pkg/mod`, `.cocoapods`, `.minikube`, `.vagrant.d`, Claude Code (versões antigas e transcripts)… | idem + `.conda`, `.nv`, virtualenvs do pipenv, pacotes `pip --user` |
| **Projetos** | `node_modules` (total agregado), artefatos de build (`.next`, `.turbo`, `target/` de Rust/Maven), git worktrees com idade e alterações locais | idem |
| **Espalhados** | Arquivos isolados > 1 GB | idem |

---

## 🚦 Níveis de risco

Toda oportunidade sai etiquetada. É a diferença entre "libera espaço" e "libera espaço e você se arrepende".

| Nível | Significa | Exemplos |
|---|---|---|
| 🟢 **SEGURO** | Regenera sozinho. Você não perde nada além de um download. | DerivedData, cache do npm, lixeira, simuladores sem runtime, cache do brew |
| 🟡 **MODERADO** | Liberável, mas custa um re-download ou rebuild. | `~/.gradle/caches`, `~/.m2/repository`, `go clean -modcache`, runtimes do Simulator |
| 🔴 **REVISAR** | Decisão manual. Pode ter dado seu dentro. | `Application Support`, Archives do Xcode, snapshots ZFS, backups de iPhone, git worktrees, arquivos grandes soltos |

Alguns itens ganham refinamento automático: um `~/.cache/pip` não vira `rm -rf` genérico,
vira `pip cache purge`. Caches do iCloud (`com.apple.bird`, `CloudDocs`, `cloudd`) são
rebaixados pra **REVISAR** mesmo estando dentro de `Caches` — apagar dispara re-sync.
Pasta de cache cheia de repositórios git (clones normais ou `--bare`) vira **MODERADO**:
nenhum app recria aquilo sozinho, só clonando de novo.

O resumo também **desduplica por contenção**: se uma pasta e sua subpasta forem
registradas, os bytes contam uma vez só. Nada de somar 400 GB num disco de 460.
Itens abaixo de 50 MB viram uma linha só por nível ("+5 itens menores").

Além dos três níveis, o resumo traz **Outras ações** — ajustes que seguram o
crescimento ou devolvem espaço sem apagar nada (limitar o cache do navegador, o
tamanho do journal, a reserva do ext4) e que ficam fora dos totais — e **Fora da
conta**: o que a varredura não conseguiu medir (sem root, Docker parado, `--quick`).

---

## 🛡 Segurança

O contrato é curto:

- **A varredura não muda nada.** Ela só chama `du`, `find`, `df` e os dry-runs
  oficiais das ferramentas (`brew cleanup -n`, `apt-get -s autoremove`,
  `docker system df`, `simctl list`, `git --no-optional-locks status`).
- **Nada roda sem você confirmar.** O menu mostra o comando exato antes de
  perguntar; o padrão da pergunta é *não*. Item **REVISAR** só roda se você digitar `sim`.
- **O que pede julgamento fica com você.** Application Support, backups de iPhone,
  `node_modules` de projetos e qualquer comando com lacuna (`<id>`, `<projeto>`) aparecem
  como *manual*: o hogspot mostra a instrução e não executa nada.
- **Path suspeito não vira comando.** Se o nome de uma pasta tem aspas, `$` ou crase,
  o item não roda pelo menu — dentro das aspas, isso viraria código.
- **Fora de um terminal, só imprime.** Em pipe, CI ou com `--no-menu` não há menu.
- **Sem rede.** Não baixa nada, não envia telemetria, não pede seu e-mail.
- **Sem daemon.** Roda, mostra, morre.
- **2.500 linhas de bash legível.** Se não confia, [leia](hogspot.sh).

---

## 🔑 Permissões

O script roda sem privilégio nenhum — mas aí ele enxerga menos, e avisa quando isso acontece.

**macOS — Full Disk Access.** Sem isso, áreas como Mail, Messages e Safari ficam
invisíveis e o total sai subestimado. Habilite em
*Ajustes do Sistema → Privacidade e Segurança → Acesso Total ao Disco* → seu terminal.

**Linux — root.** `/var/lib/docker`, o journal, `/var/crash`, o cache do snapd e
`/root` não são legíveis pelo seu usuário. Pra contar tudo (a varredura continua read-only):

```bash
sudo HOME="$HOME" ./hogspot.sh
```

Rodando assim, os comandos do menu que não começam com `sudo` (`npm cache clean`,
`brew cleanup`, `rm` em caches da sua home) rodam como o seu usuário, não como root.

---

## 📄 Relatório em markdown

```bash
./hogspot.sh --report ~/Downloads/hogspot-$(date +%F).md
```

Salva o relatório completo — todas as seções mais o resumo, com o comando de cada
item — sem códigos de cor. Bom pra comparar dois scans, anexar num ticket ou guardar
antes de vender o Mac. No menu, `s` faz o mesmo.

---

## 💻 Requisitos

|  | |
|---|---|
| **SO** | macOS (qualquer versão recente) ou Linux — Ubuntu/Debian em primeiro lugar, mas Fedora e Arch também são detectados |
| **Shell** | `bash` 3.2+ (o que já vem no macOS; nada de bash 5 obrigatório) |
| **Ferramentas** | `du`, `find`, `df`, `awk`, `sort` — POSIX básico |
| **Opcionais** | `tmutil`, `sw_vers`, `xcrun`, `brew`, `docker`, `git`, `apt-get`, `dpkg`, `snap`, `flatpak`, `journalctl`, `swapon`, `zfs`, `timeshift` — cada um só é usado se estiver presente |

---

## 🤝 Contribuindo

Issues e PRs são bem-vindos. Duas coisas ajudam muito:

1. **Um cache que faltou.** Se você tem uma pasta gigante de alguma ferramenta que o
   `hogspot` ignora, abra uma issue com o caminho, o tamanho e o comando oficial de
   limpeza. É o tipo de contribuição que mais melhora o script.
2. **Saída em outra distro.** O suporte a Linux nasceu focado em Ubuntu/Debian —
   relatos de Fedora, Arch, openSUSE e afins são ouro.

Antes de mandar PR: mantenha a varredura **read-only** (só o menu executa, e só com
confirmação), sem dependências novas e compatível com `bash` 3.2. Passe o `shellcheck`.
Nas mensagens, o tom é o de um colega na mesa do lado: direto, sem urgência falsa
("seu disco está crítico!") e sem exclamação em ação normal.

---

## 📜 Licença

[MIT](LICENSE). Use, modifique e redistribua à vontade. O script é fornecido como
está, sem garantia: ele mostra o comando antes de rodar justamente pra decisão ser sua.

---

<div align="center">
<sub>

**hogspot** — *hog* (o processo/arquivo que come recurso) + *spot* (achar).
O lugar onde os porcões se escondem. Nunca `HogSpot`.

</sub>
</div>
