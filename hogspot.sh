#!/usr/bin/env bash
# =============================================================================
#  hogspot — encontra onde os "disk hogs" estão escondidos na sua máquina
#  A varredura é read-only. Cada oportunidade sai classificada por risco
#  (SEGURO / MODERADO / REVISAR) com o comando que libera o espaço; no
#  terminal, um menu deixa rodar esses comandos — só depois da sua confirmação.
#
#  Uso:
#    hogspot                  # resumo do que dá pra limpar + menu
#    hogspot --full           # relatório completo, seção por seção, antes do resumo
#    hogspot --top 20         # itens por seção no relatório completo (default: 15)
#    hogspot --report ARQUIVO # salva o relatório completo em arquivo (markdown)
#    hogspot --quick          # pula scans demorados (projetos e arquivos gigantes)
#    hogspot --detail         # abre a composição interna dos caches de dev
#    hogspot --no-menu        # só imprime, sem perguntar nada no fim
#    hogspot --no-color       # sem cores
#    hogspot --help           # ajuda
#
#  Suporta: macOS e Linux (Ubuntu/Debian em primeiro lugar).
#  Usa apenas ferramentas padrão: du, find, df + tmutil/sw_vers no macOS e
#  dpkg/snap/flatpak/journalctl no Linux (cada um só quando presente).
#
#  Licença: MIT (veja LICENSE) — https://github.com/trentas/hogspot
# =============================================================================

set -uo pipefail

# ----- Configuração -----
TOP_N=15
REPORT_FILE=""
QUICK=0
DETAIL=0
FULL=0
MENU=1
USE_COLOR=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --top)       TOP_N="$2"; shift 2 ;;
    --report)    REPORT_FILE="$2"; shift 2 ;;
    --quick)     QUICK=1; shift ;;
    --detail)    DETAIL=1; shift ;;
    --full)      FULL=1; shift ;;
    --no-menu)   MENU=0; shift ;;
    --no-color)  USE_COLOR=0; shift ;;
    --help|-h)
      # imprime o bloco de comentário do topo (entre as duas réguas de '=')
      awk '/^# ={10,}/ { n++; next } n == 1 { sub(/^# ?/, ""); print } n > 1 { exit }' "$0"
      exit 0 ;;
    *)
      echo "Opção desconhecida: $1" >&2
      exit 1 ;;
  esac
done

if ! [[ "$TOP_N" =~ ^[1-9][0-9]*$ ]]; then
  echo "Valor inválido para --top: $TOP_N (esperado número > 0)" >&2
  exit 1
fi

# ----- Plataforma -----
case "$(uname -s)" in
  Darwin) OS=macos ;;
  Linux)  OS=linux ;;
  *)
    echo "hogspot suporta macOS e Linux (detectado: $(uname -s))" >&2
    exit 1 ;;
esac

# Gerenciador de pacotes do sistema (Linux) — define os comandos sugeridos
PKG=""
if [[ $OS == linux ]]; then
  if   command -v apt-get >/dev/null 2>&1; then PKG=apt
  elif command -v dnf     >/dev/null 2>&1; then PKG=dnf
  elif command -v pacman  >/dev/null 2>&1; then PKG=pacman
  fi
fi

# Diretórios equivalentes entre as duas plataformas
if [[ $OS == macos ]]; then
  CACHE_DIR="$HOME/Library/Caches"
  APPDATA_DIR="$HOME/Library/Application Support"
  # No macOS não limitamos o find a um filesystem: CloudStorage e volumes
  # montados dentro da home podem ser justamente o que está pesando.
  XDEV=""
else
  CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
  APPDATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
  # No Linux a home costuma ter mounts alheios (gvfs, NFS, disco externo);
  # -xdev evita varrer o que não é disco local.
  XDEV="-xdev"
fi

# Pasta de downloads (respeita o XDG no Linux)
DOWNLOADS_DIR="$HOME/Downloads"
if [[ $OS == linux ]] && command -v xdg-user-dir >/dev/null 2>&1; then
  _xdg_dl=$(xdg-user-dir DOWNLOAD 2>/dev/null || true)
  if [[ -n "${_xdg_dl:-}" && -d "${_xdg_dl:-}" && "${_xdg_dl:-}" != "$HOME" ]]; then
    DOWNLOADS_DIR="$_xdg_dl"
  fi
fi

# Sem TTY → sem cor
[[ -t 1 ]] || USE_COLOR=0

# O menu só faz sentido com alguém do outro lado (stdin e stdout no terminal)
[[ -t 0 && -t 1 ]] || MENU=0

# Itens abaixo disso somem das listas do relatório (ruído)
MIN_LIST_KB=10240        # 10 MB
# e, no resumo, viram uma linha "+N itens menores" por nível de risco
MIN_SUMMARY_BYTES=52428800   # 50 MB

if [[ $USE_COLOR -eq 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
else
  C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

# ----- Helpers -----

out() {
  printf '%b\n' "$*"
}

# Encurta um path pra exibição: /home/foo/.cache → ~/.cache
# (o '~' vem de variável: escapado como \~ o bash 3.2 do macOS mantém a barra)
tilde() {
  local t='~'
  printf '%s\n' "${1/#$HOME/$t}"
}

# Roda um comando em background com spinner no stderr.
# Captura stdout em buffer e despeja só quando terminar
# (mantém o spinner numa linha só, sem interleaving).
# Se não houver TTY ou cor desabilitada, roda direto sem spinner.
run_spun() {
  local msg="$1"; shift
  if [[ $USE_COLOR -eq 0 || ! -t 2 ]]; then
    "$@"
    return $?
  fi
  local tmp; tmp=$(mktemp)
  ( "$@" >"$tmp" 2>/dev/null ) &
  local pid=$!
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r\033[K  %s%s%s %s' "$C_CYAN" "${frames[i]}" "$C_RESET" "$msg" >&2
    i=$(( (i+1) % ${#frames[@]} ))
    sleep 0.1
  done
  wait "$pid" 2>/dev/null
  local rc=$?
  printf '\r\033[K' >&2
  [[ -n "$STATUS_MSG" ]] && status "$STATUS_MSG"
  cat "$tmp"
  rm -f "$tmp"
  return $rc
}

# No modo resumo o relatório vai pra um arquivo; uma linha de status no
# stderr diz em que parte da varredura estamos (os spinners se sobrepõem a ela)
SHOW_STATUS=0
[[ $FULL -eq 0 && $USE_COLOR -eq 1 && -t 2 ]] && SHOW_STATUS=1
STATUS_MSG=""
status() {
  [[ $SHOW_STATUS -eq 1 ]] || return 0
  STATUS_MSG="$1"
  printf '\r\033[K  %s⠿%s analisando: %s' "$C_CYAN" "$C_RESET" "$STATUS_MSG" >&2
}

# ----- Registro de oportunidades (pra ranking final) -----
OPPS_FILE=$(mktemp)
BLIND_FILE=$(mktemp)   # o que ficou fora da conta (sem root, daemon parado...)
FULL_OUT=$(mktemp)     # relatório completo, seção por seção

# Níveis de risco:
#   SEGURO   — regenera sozinho (cache, artefato de build, lixeira)
#   MODERADO — liberável, mas custa re-download/rebuild
#   REVISAR  — potencial perda de dados; decisão manual
#
# register_opp <bytes> <risco> <path-ou-vazio> <descrição> <comando>
# path é usado pra deduplicar itens sobrepostos no ranking final.
# Ignora silenciosamente se bytes for vazio/zero/inválido.
register_opp() {
  local bytes="$1" risk="$2" path="$3" desc="$4" cmd="$5"
  [[ -z "$bytes" || ! "$bytes" =~ ^[0-9]+$ || "$bytes" -le 0 ]] && return 0
  printf '%s\t%s\t%s\t%s\t%s\n' "$bytes" "$risk" "$path" "$desc" "$cmd" >> "$OPPS_FILE"
}

# Ajuste de configuração (limite de cache, reserva do ext4...): não entra nos
# totais por risco, mas aparece no resumo e pode ser rodado pelo menu.
# register_tip <bytes-ou-0> <descrição> <comando>
register_tip() {
  local bytes="${1:-0}"
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
  printf '%s\t%s\t%s\t%s\t%s\n' "$bytes" "AJUSTE" "" "$2" "$3" >> "$OPPS_FILE"
}

# register_blind <texto> — algo que a varredura não conseguiu medir
register_blind() {
  printf '%s\n' "$1" >> "$BLIND_FILE"
}

# Path que pode ir entre aspas duplas num comando sem mudar o sentido dele.
# Os comandos sugeridos interpolam paths do disco e o menu os executa: um
# nome de pasta com aspas, $ ou crase viraria código.
shell_safe() {
  case "$1" in
    *[\"\$\`\\]*|*$'\n'*) return 1 ;;
  esac
  return 0
}

# Caches que NÃO devem ser apagados às cegas: guardam estado do iCloud/sistema
# e apagar dispara re-sync ou comportamento estranho.
RISKY_CACHE_RE='com\.apple\.bird|CloudDocs|com\.apple\.cloudd|com\.apple\.Safari|com\.apple\.homed|FamilyCircle'

# Refina risco/comando de um item de cache conhecido (usado pelas seções de
# cache). Ecoa "risco<TAB>comando" quando conhece o item; nada quando não —
# aí o chamador mantém o genérico da seção.
refine_cache_item() {
  local path="$1" base clones
  base=$(basename "$path")
  if [[ $OS == macos && "$base" =~ $RISKY_CACHE_RE ]]; then
    printf 'REVISAR\t%s\n' "# cache do iCloud/sistema — apagar pode disparar re-sync; deixe o macOS gerenciar"
    return 0
  fi
  refine_known_cache "$path" "$base" && return 0
  # Clones git largados no cache (scripts que clonam repositórios pra
  # analisar) não voltam sozinhos como o cache de um app: só clonando de novo.
  # Vem depois dos conhecidos: Homebrew, pre-commit e Nix também guardam
  # clones, mas refazem sozinhos.
  clones=$(count_git_repos "$path")
  if [[ $clones -gt 0 ]]; then
    printf 'MODERADO\t%s\n' "rm -rf \"$path\"  # $clones repositório(s) git: só voltam clonando de novo — confira se algo ainda usa"
  fi
  return 0
}

# Repositórios git até 2 níveis abaixo de um diretório: com .git (clone
# normal) ou bare (HEAD + objects/ + refs/ direto na pasta, como deixa um
# git clone --bare)
count_git_repos() {
  find "$1" -mindepth 1 -maxdepth 3 \( -name .git -o -name HEAD -type f \) 2>/dev/null \
    | while IFS= read -r g; do
        case "$g" in
          */.git) echo "$g" ;;
          */.git/HEAD) ;;   # o HEAD de dentro de um .git já contou
          */HEAD) [[ -d "${g%/HEAD}/objects" && -d "${g%/HEAD}/refs" ]] && echo "$g" ;;
        esac
      done \
    | wc -l | tr -d ' '
}

# Caches com comando próprio de limpeza (melhor que um rm -rf genérico).
# Os nomes valem nas duas plataformas (~/.cache e ~/Library/Caches).
# Retorna 1 quando não conhece o item.
refine_known_cache() {
  local path="$1" base="$2"
  case "$base" in
    pip)            printf 'SEGURO\t%s\n'   "pip cache purge" ;;
    uv)             printf 'SEGURO\t%s\n'   "uv cache clean" ;;
    yarn)           printf 'SEGURO\t%s\n'   "yarn cache clean" ;;
    go-build)       printf 'SEGURO\t%s\n'   "go clean -cache" ;;
    ms-playwright)  printf 'SEGURO\t%s\n'   "npx playwright uninstall --all" ;;
    Homebrew)       printf 'SEGURO\t%s\n'   "brew cleanup -s --prune=all" ;;
    tracker3)
      if command -v localsearch >/dev/null 2>&1; then
        printf 'SEGURO\t%s\n' "localsearch reset -s  # índice da busca do GNOME; reindexa sozinho"
      else
        printf 'SEGURO\t%s\n' "tracker3 reset -s  # índice da busca do GNOME; reindexa sozinho"
      fi ;;
    thumbnails)     printf 'SEGURO\t%s\n'   "rm -rf \"$path\"  # miniaturas do gerenciador de arquivos; regeneram" ;;
    JetBrains)      printf 'SEGURO\t%s\n'   "rm -rf \"$path\"  # caches/índices das IDEs; reindexam ao abrir" ;;
    mesa_shader_cache|mesa_shader_cache_db|nvidia|fontconfig)
                    printf 'SEGURO\t%s\n'   "rm -rf \"$path\"  # cache de GPU/fontes; regenera sozinho" ;;
    google-chrome|chromium|BraveSoftware|microsoft-edge|vivaldi|mozilla)
                    printf 'SEGURO\t%s\n'   "rm -rf \"$path\"  # cache do navegador (feche o app antes)" ;;
    huggingface)    printf 'MODERADO\t%s\n' "rm -rf \"$path/hub\"  # modelos re-baixam ao usar" ;;
    pre-commit)     printf 'MODERADO\t%s\n' "pre-commit clean" ;;
    bazel|bazelisk) printf 'MODERADO\t%s\n' "bazel clean --expunge  # rebuild refaz tudo" ;;
    nix)            printf 'SEGURO\t%s\n'   "rm -rf \"$path\"  # cache de downloads do Nix; baixa de novo sozinho" ;;
    *) return 1 ;;
  esac
  return 0
}

# Itens de dados de app que outra seção mede com mais precisão: ecoa
# "-<TAB>nota" (mostra na lista, mas não registra — senão o dedup do ranking
# engole a linha específica, que é menor que a pasta inteira)
refine_appdata_item() {
  [[ $OS == linux ]] || return 0
  case "$(basename "$1")" in
    claude) printf -- '-\t%s\n' "Claude Code: só as versões antigas contam, na seção de caches de dev" ;;
  esac
  return 0
}

# Converte string tipo "7.3GB", "34.6 MB", "1.8GB (72%)" em bytes.
# $2 = "si" pra unidades decimais (Docker/Podman: 1 GB = 10^9 bytes);
# sem ele, binárias (Homebrew, journalctl)
parse_size_to_bytes() {
  awk -v s="$1" -v si="${2:-}" 'BEGIN {
    n = s + 0   # parte numérica inicial
    k = (si == "si") ? 1000 : 1024
    if (s ~ /[Tt]B?/) mult = k * k * k * k
    else if (s ~ /[Gg]B?/) mult = k * k * k
    else if (s ~ /[Mm]B?/) mult = k * k
    else if (s ~ /[Kk]B?/) mult = k
    else mult = 1
    printf "%d\n", n * mult
  }'
}

# Soma uma coluna do '<docker|podman> system df' em bytes (Size, Reclaimable)
container_df_bytes() {
  "$1" system df --format "{{.$2}}" 2>/dev/null \
    | while IFS= read -r line; do
        # cada linha: "1.8GB (72%)" ou "0B"
        parse_size_to_bytes "${line%% *}" si
      done \
    | awk '{s+=$1} END {print s+0}'
}

# Limpa spinner e arquivos temporários ao sair (um trap só; INT/TERM
# viram exit pra não sobrescrever a limpeza no modo --report)
cleanup() {
  [[ -t 2 ]] && printf '\r\033[K' >&2
  rm -f "$OPPS_FILE" "$BLIND_FILE" "$FULL_OUT"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

section() {
  status "${*%% — top*}"
  out ""
  out "${C_BOLD}${C_CYAN}━━ $* ━━${C_RESET}"
  out ""
}

# Seção que só aparece quando o corpo imprime algo — sem "nada encontrado"
# ocupando tela. O corpo roda num subshell: registra oportunidades
# normalmente (vão pra arquivo), mas variáveis que ele define não voltam.
# section_if <título> <função> [args...]
section_if() {
  local title="$1" body
  shift
  status "$title"
  body=$("$@")
  [[ -n "$body" ]] || return 0
  section "$title"
  printf '%s\n' "$body"
}

note() {
  out "${C_DIM}$*${C_RESET}"
}

# Lista top N filhos de um diretório por tamanho
top_children() {
  local dir="$1"
  local n="${2:-$TOP_N}"
  [[ -d "$dir" ]] || { note "  (não existe: $dir)"; return; }
  # du -k + human_bytes (não du -h, que arredonda pra cima): o mesmo diretório
  # aparece com o mesmo número em todas as seções
  du -sk "$dir"/* "$dir"/.[!.]* 2>/dev/null \
    | sort -rn \
    | awk -F'\t' -v min="$MIN_LIST_KB" '$1 >= min' \
    | head -n "$n" \
    | while IFS=$'\t' read -r kb path; do
        printf '  %8s  %s%s%s\n' "$(human_bytes $((kb * 1024)))" "$C_DIM" "$path" "$C_RESET"
      done
}

# Como top_children, mas também registra cada entry como oportunidade.
# $3 = risco, $4 = label (prefixo da descrição), $5 = template do comando ({} = path)
top_children_register() {
  local dir="$1" n="${2:-$TOP_N}" risk="$3" label="$4" cmd_tpl="$5"
  [[ -d "$dir" ]] || { note "  (não existe: $dir)"; return; }
  du -sk "$dir"/* "$dir"/.[!.]* 2>/dev/null \
    | sort -rn \
    | awk -F'\t' -v min="$MIN_LIST_KB" '$1 >= min' \
    | head -n "$n" \
    | while IFS=$'\t' read -r kb path; do
        [[ -z "$kb" || -z "$path" ]] && continue
        local bytes=$((kb * 1024))
        local item_risk="$risk" cmd="${cmd_tpl//\{\}/$path}" refined="" tag=""
        # Itens conhecidos ganham risco/comando mais precisos
        if [[ "$item_risk" == "SEGURO" ]]; then
          refined=$(refine_cache_item "$path")
        elif [[ "$dir" == "$APPDATA_DIR" ]]; then
          refined=$(refine_appdata_item "$path")
        fi
        if [[ -n "$refined" ]]; then
          item_risk="${refined%%$'\t'*}"
          cmd="${refined#*$'\t'}"
          if [[ "$item_risk" == "-" ]]; then
            tag="  ($cmd)"   # nota de onde o item é medido de verdade
          elif [[ "$item_risk" != "$risk" ]]; then
            tag="  [$item_risk]"
          fi
        fi
        printf '  %8s  %s%s%s%s\n' "$(human_bytes "$bytes")" "$C_DIM" "$path" "$tag" "$C_RESET"
        [[ "$item_risk" == "-" ]] && continue
        register_opp "$bytes" "$item_risk" "$path" "$label: $(basename "$path")" "$cmd"
      done
}

# Procura arquivos grandes (>=MIN MB) num diretório, limitando profundidade
big_files() {
  local dir="$1"
  local min_mb="${2:-500}"
  local depth="${3:-4}"
  local n="${4:-$TOP_N}"
  [[ -d "$dir" ]] || return
  # -exec em vez de xargs: sem resultado, o xargs do GNU roda 'du' sem
  # argumentos e mede o diretório atual
  # shellcheck disable=SC2086  # $XDEV é uma flag só (ou vazio)
  find "$dir" $XDEV -maxdepth "$depth" -type f -size +"${min_mb}"M -exec du -k {} + 2>/dev/null \
    | sort -rn \
    | head -n "$n" \
    | while IFS=$'\t' read -r kb f; do
        printf '  %8s  %s%s%s\n' "$(human_bytes $((kb * 1024)))" "$C_DIM" "$f" "$C_RESET"
      done
}

# Como big_files, mas mede em KB e registra cada arquivo como oportunidade
big_files_register() {
  local dir="$1" min_mb="$2" depth="$3" n="$4" risk="$5" label="$6"
  [[ -d "$dir" ]] || return 0
  local found
  # shellcheck disable=SC2086
  found=$(find "$dir" $XDEV -maxdepth "$depth" -type f -size +"${min_mb}"M -exec du -k {} + 2>/dev/null \
    | sort -rn | head -n "$n")
  if [[ -z "$found" ]]; then
    note "  (nenhum arquivo acima de ${min_mb} MB)"
    return 0
  fi
  while IFS=$'\t' read -r kb f; do
    [[ -z "$kb" || -z "$f" ]] && continue
    printf '  %8s  %s%s%s\n' "$(human_bytes $((kb * 1024)))" "$C_DIM" "$f" "$C_RESET"
    register_opp "$((kb * 1024))" "$risk" "$f" "$label: $(basename "$f")" "# revisar: $f"
  done <<< "$found"
}

# under_any <path> <raízes, uma por linha> — path está dentro de alguma raiz?
under_any() {
  local root
  while IFS= read -r root; do
    [[ -n "$root" && "$1" == "$root"/* ]] && return 0
  done <<< "$2"
  return 1
}

# Lista as 10 maiores pastas de um grupo (uma por linha) e deixa o total em
# GROUP_COUNT/GROUP_BYTES pro chamador registrar
dir_group() {
  local list="$1" p kb
  GROUP_COUNT=0 GROUP_BYTES=0
  [[ -n "$list" ]] || return 0
  GROUP_COUNT=$(printf '%s' "$list" | grep -c .)
  while IFS= read -r p; do
    [[ -n "$p" ]] && du -sk "$p" 2>/dev/null
  done <<< "$list" \
    | sort -rn \
    | head -10 \
    | while IFS=$'\t' read -r kb p; do
        printf '  %8s  %s%s%s\n' "$(human_bytes $((kb * 1024)))" "$C_DIM" "$p" "$C_RESET"
      done
  # Total numa chamada só: o du conta hardlinks uma vez (node_modules do pnpm
  # apontam pro store, e somar pasta por pasta inflaria o número)
  kb=$(printf '%s' "$list" | tr '\n' '\0' | xargs -0 du -skc 2>/dev/null \
    | awk -F'\t' '$2 == "total" { s += $1 } END { print s + 0 }')
  GROUP_BYTES=$((kb * 1024))
}

# Uma varredura só pelo $HOME atrás de lixo de projeto: node_modules,
# artefatos de build e git worktrees. Pula as pastas ocultas do topo da home
# (caches de ferramenta têm seção própria, e o node_modules global do
# nvm/mise não é descartável) e as áreas de app (~/Library, ~/snap).
# Worktrees entram inteiras como REVISAR; o que está dentro delas não é
# contado de novo nos totais de node_modules/builds.
scan_projects() {
  local list p gitdir wts="" nm_list="" art_list="" kb wt main ct days dirty info now wt_cmd
  # shellcheck disable=SC2086
  list=$(find "$HOME" $XDEV \
      \( -path "$HOME/.*" -o -path "$HOME/Library" -o -path "$HOME/snap" -o -path "$HOME/go/pkg" \
         -o \( -name .git -type d \) \) -prune -o \
      \( -type d \( -name node_modules -o -name .next -o -name .nuxt -o -name .svelte-kit \
                   -o -name .turbo -o -name .parcel-cache -o -name target \) -prune -print \) -o \
      \( -type f -name .git -print \) 2>/dev/null)

  # Numa worktree o .git é um arquivo "gitdir: <repo>/.git/worktrees/<nome>"
  # (em submódulo também é arquivo, mas aponta pra .git/modules)
  while IFS= read -r p; do
    [[ "$(basename "$p")" == .git && -f "$p" ]] || continue
    gitdir=$(sed -n 's/^gitdir: //p' "$p" 2>/dev/null)
    [[ "$gitdir" == */worktrees/* ]] && wts+="$(dirname "$p")"$'\n'
  done <<< "$list"

  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    under_any "$p" "$wts" && continue
    case "$(basename "$p")" in
      .git) ;;
      node_modules) nm_list+="$p"$'\n' ;;
      target)  # só build de Rust/Maven; 'target' é nome comum demais
        [[ -f "$(dirname "$p")/Cargo.toml" || -f "$(dirname "$p")/pom.xml" ]] && art_list+="$p"$'\n' ;;
      *) art_list+="$p"$'\n' ;;
    esac
  done <<< "$list"

  note "node_modules (top 10):"
  if [[ -n "$nm_list" ]]; then
    dir_group "$nm_list"
    out "  ${C_BOLD}Total: ${GROUP_COUNT} pasta(s), $(human_bytes "$GROUP_BYTES")${C_RESET}"
    register_opp "$GROUP_BYTES" "SEGURO" "" "node_modules: ${GROUP_COUNT} pasta(s) de projeto" \
      "rm -rf <projeto>/node_modules  # nos projetos parados; npm/pnpm install regenera"
  else
    note "  (nenhum)"
  fi

  if [[ -n "$art_list" ]]; then
    out ""
    note "Artefatos de build (.next, .turbo, target/ de Rust/Maven...) — top 10:"
    dir_group "$art_list"
    out "  ${C_BOLD}Total: ${GROUP_COUNT} pasta(s), $(human_bytes "$GROUP_BYTES")${C_RESET}"
    register_opp "$GROUP_BYTES" "SEGURO" "" "Artefatos de build: ${GROUP_COUNT} pasta(s)" \
      "rm -rf <pasta>  # o próximo build regenera (Rust: cargo clean; Maven: mvn clean)"
  fi

  if [[ -n "$wts" ]]; then
    out ""
    note "Git worktrees (checkout completo cada uma, com node_modules próprio):"
    now=$(date +%s)
    while IFS= read -r wt; do
      [[ -n "$wt" ]] && du -sk "$wt" 2>/dev/null
    done <<< "$wts" \
      | sort -rn \
      | while IFS=$'\t' read -r kb wt; do
          gitdir=$(sed -n 's/^gitdir: //p' "$wt/.git" 2>/dev/null)
          [[ "$gitdir" == /* ]] || gitdir="$wt/$gitdir"   # git >= 2.48 aceita path relativo
          main="${gitdir%/worktrees/*}"; main="${main%/.git}"
          ct=$(git -C "$wt" log -1 --format=%ct 2>/dev/null)
          days=$(( (now - ${ct:-$now}) / 86400 ))
          # --no-optional-locks: o status não reescreve o .git/index (read-only)
          dirty=$(git -C "$wt" --no-optional-locks status --porcelain 2>/dev/null | wc -l)
          if [[ $days -eq 0 ]]; then info="último commit hoje"; else info="último commit há ${days}d"; fi
          info+=", $((dirty + 0)) alteração(ões) local(is)"
          printf '  %8s  %s%s%s  %s(%s)%s\n' "$(human_bytes $((kb * 1024)))" \
            "$C_DIM" "$wt" "$C_RESET" "$C_DIM" "$info" "$C_RESET"
          wt_cmd="git -C \"$main\" worktree remove \"$wt\"  # --force descarta alterações locais"
          shell_safe "$main" || wt_cmd="# remova pelo git: $wt_cmd"
          register_opp "$((kb * 1024))" "REVISAR" "$wt" "Worktree git: $(basename "$wt") ($info)" "$wt_cmd"
        done
  fi
}

# Linha de breakdown interno + registro (usada por detail_dev_cache).
# detail_item <path> <risco> <descrição> <comando>
detail_item() {
  local path="$1" risk="$2" desc="$3" cmd="$4"
  [[ -e "$path" ]] || return 0
  local kb; kb=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
  local bytes=$(( ${kb:-0} * 1024 ))
  [[ $bytes -gt 0 ]] || return 0
  local tag_color="$C_RED"
  [[ "$risk" == "SEGURO" ]] && tag_color="$C_GREEN"
  [[ "$risk" == "MODERADO" ]] && tag_color="$C_YELLOW"
  printf '  %8s    ↳ %s[%s]%s %s%s%s\n' "$(human_bytes "$bytes")" \
    "$tag_color" "$risk" "$C_RESET" "$C_DIM" "$desc" "$C_RESET"
  register_opp "$bytes" "$risk" "$path" "$desc" "$cmd"
  return 0
}

# Composição interna de caches de dev conhecidos (modo --detail).
# Registra oportunidades por subpasta — mais precisas que o dir inteiro
# (ex.: dentro de ~/.npm, o _cacache é SEGURO; dentro de ~/.cargo, o
# registry é MODERADO mas o bin/ tem binários instalados).
# Retorna 1 quando não conhece o dir → o chamador registra o genérico.
detail_dev_cache() {
  local key="$1" p="$2"
  case "$key" in
    .npm)
      detail_item "$p/_cacache" "SEGURO" "npm cache (~/.npm/_cacache)" "npm cache clean --force"
      detail_item "$p/_npx"     "SEGURO" "pacotes npx (~/.npm/_npx)"   "rm -rf \"$p/_npx\"  # re-instalam quando usados"
      ;;
    Library/pnpm|.local/share/pnpm)
      detail_item "$p/store" "MODERADO" "pnpm store" "pnpm store prune  # remove só pacotes órfãos"
      [[ -d "$p/store" ]] && note "              dica: apague node_modules de projetos mortos antes do prune"
      ;;
    .gradle)
      detail_item "$p/caches"        "MODERADO" "Gradle caches"                  "rm -rf \"$p/caches\"  # rebuild baixa de novo"
      detail_item "$p/wrapper/dists" "MODERADO" "Gradle wrapper (distribuições)" "# mantenha só a versão em uso: ls \"$p/wrapper/dists\""
      ;;
    .cache)
      detail_item "$p/pip"           "SEGURO"   "cache do pip"           "pip cache purge"
      detail_item "$p/uv"            "SEGURO"   "cache do uv"            "uv cache clean"
      detail_item "$p/huggingface"   "MODERADO" "modelos HuggingFace"    "rm -rf \"$p/huggingface/hub\"  # modelos re-baixam ao usar"
      detail_item "$p/ms-playwright" "SEGURO"   "browsers do Playwright" "npx playwright uninstall --all"
      ;;
    .cargo)
      detail_item "$p/registry" "MODERADO" "cargo registry" "rm -rf \"$p/registry\"  # re-baixa no próximo build"
      detail_item "$p/git"      "MODERADO" "cargo git deps" "rm -rf \"$p/git\""
      ;;
    *) return 1 ;;
  esac
  return 0
}

# No Linux, áreas do sistema (/var/lib/docker, journal, crashes) só são
# legíveis como root — sem sudo o relatório subconta do mesmo jeito.
system_dirs_readable() {
  local probe
  for probe in /var/lib/docker /var/log/journal /var/crash /var/lib/systemd/coredump /root; do
    [[ -d "$probe" ]] || continue
    ls "$probe" >/dev/null 2>&1 || return 1
  done
  return 0
}

# Nome do sistema pro cabeçalho do relatório
os_label() {
  if [[ $OS == macos ]]; then
    printf '%s %s\n' "$(sw_vers -productName 2>/dev/null)" "$(sw_vers -productVersion 2>/dev/null)"
  else
    local pretty=""
    [[ -r /etc/os-release ]] && pretty=$(
      # shellcheck disable=SC1091
      . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-${NAME:-}}"
    )
    printf '%s (kernel %s)\n' "${pretty:-Linux}" "$(uname -r)"
  fi
}

# Linha "X em uso de Y (Z%) — livre: W" pra um filesystem
# fs_summary <path> <rótulo>
fs_summary() {
  local target="$1" label="$2" size_kb used_kb avail_kb pct extra=""
  read -r size_kb used_kb avail_kb <<< "$(df -Pk "$target" 2>/dev/null | awk 'NR==2 {print $2, $3, $4}')"
  [[ "${size_kb:-0}" -gt 0 ]] || return 0
  if [[ $OS == macos ]]; then
    # APFS: o "used" do df é só deste volume; o container inteiro é size - avail
    used_kb=$((size_kb - avail_kb))
  else
    # ext4 reserva blocos pro root (5% por padrão): nem em uso, nem livres
    local reserved_kb=$((size_kb - used_kb - avail_kb))
    [[ $reserved_kb -gt 0 ]] && extra=" — reservado ao root: $(human_bytes $((reserved_kb * 1024)))"
  fi
  # Arredonda pra cima, como o Use% do df (senão a linha acima diz 99% e esta 98%)
  local denom=$(( used_kb + avail_kb > 0 ? used_kb + avail_kb : 1 ))
  pct=$(( (used_kb * 100 + denom - 1) / denom ))
  out "  ${C_BOLD}${label}: $(human_bytes $((used_kb * 1024))) em uso de $(human_bytes $((size_kb * 1024))) (${pct}%) — livre: $(human_bytes $((avail_kb * 1024)))${extra}${C_RESET}"
}

# Mesmo filesystem? (Downloads pode ser link pra pasta do host numa VM, pra
# disco externo ou rede — apagar lá não libera nada no disco da home)
same_fs() {
  [[ "$(df -P "$1" 2>/dev/null | awk 'NR==2 {print $1}')" == \
     "$(df -P "$2" 2>/dev/null | awk 'NR==2 {print $1}')" ]]
}

# Mede um diretório do sistema, imprime a linha e registra a oportunidade.
# Silencioso quando o diretório não existe ou está vazio.
# Risco "-" só imprime (quando outra linha já registra esse espaço).
# sys_report_dir <path> <risco> <descrição> <comando>
sys_report_dir() {
  local path="$1" risk="$2" desc="$3" cmd="$4" kb bytes
  [[ -d "$path" ]] || return 0
  # Sem permissão o du mede só a entrada do diretório (4 KB) — número falso.
  # Diz que não deu pra medir; se outra linha já cobre esse espaço, nem isso.
  if [[ ! -r "$path" || ! -x "$path" ]]; then
    [[ "$risk" == "-" ]] || printf '  %8s  %s  %s(só root lê)%s\n' "?" "$path" "$C_DIM" "$C_RESET"
    return 0
  fi
  kb=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
  [[ ${kb:-0} -ge $MIN_LIST_KB ]] || return 0
  bytes=$((kb * 1024))
  printf '  %8s  %s\n' "$(human_bytes "$bytes")" "$path"
  [[ "$risk" == "-" ]] || register_opp "$bytes" "$risk" "$path" "$desc" "$cmd"
}

# Onde ficam as lixeiras (a do usuário + as de volumes/mídias removíveis)
trash_locations() {
  if [[ $OS == macos ]]; then
    printf '%s\n' "$HOME/.Trash"
    ls -d /Volumes/*/.Trashes 2>/dev/null || true
  else
    printf '%s\n' "$APPDATA_DIR/Trash"
    ls -d /media/"$(id -un)"/*/.Trash-"$(id -u)" \
          /run/media/"$(id -un)"/*/.Trash-"$(id -u)" 2>/dev/null || true
  fi
}

# Comando pra esvaziar a lixeira na plataforma atual
empty_trash_cmd() {
  if [[ $OS == macos ]]; then
    printf '%s\n' "osascript -e 'tell application \"Finder\" to empty trash'"
  elif command -v gio >/dev/null 2>&1; then
    printf '%s\n' "gio trash --empty"
  else
    printf '%s\n' "rm -rf \"$APPDATA_DIR/Trash\"/files/* \"$APPDATA_DIR/Trash\"/info/*"
  fi
}

# Sem Full Disk Access, du falha silenciosamente em áreas protegidas por TCC
# (Mail, Messages, Safari) e o relatório subconta. Detecta sondando uma delas.
has_full_disk_access() {
  local probe
  for probe in "$HOME/Library/Mail" "$HOME/Library/Messages" "$HOME/Library/Safari"; do
    [[ -e "$probe" ]] || continue
    ls "$probe" >/dev/null 2>&1
    return $?
  done
  return 0
}

# Bytes humanos a partir de bytes crus
human_bytes() {
  local b="$1"
  awk -v b="$b" 'BEGIN{
    split("B KB MB GB TB PB", u);
    i=1; while(b>=1024 && i<6){ b/=1024; i++ }
    printf "%.1f %s\n", b, u[i]
  }'
}

# =============================================================================
# SEÇÕES ESPECÍFICAS DE PLATAFORMA
# =============================================================================

# --- Visão geral do disco -----------------------------------------------------

disk_overview_macos() {

# No macOS moderno "/" é o volume selado do sistema (pequeno, read-only);
# os dados do usuário vivem em /System/Volumes/Data, no mesmo container
# APFS, e o espaço livre é compartilhado entre todos os volumes. Olhar só
# o "/" subestima (muito) o uso real do disco.
DATA_VOL="/System/Volumes/Data"
[[ -d "$DATA_VOL" ]] || DATA_VOL="/"
df -h / "$DATA_VOL" 2>/dev/null \
  | awk 'NR==1 { printf "  %s\n", $0; next } !seen[$1]++ { printf "  %s\n", $0 }'

out ""
fs_summary "$DATA_VOL" "Container APFS"
note "  Seus arquivos contam no volume Data. O Finder pode mostrar mais espaço livre"
note "  porque inclui o 'purgeable' (snapshots, caches que o macOS descarta sozinho)."

# Volumes APFS extras (snapshots ocupam aqui)
out ""
note "Volumes APFS (inclui snapshots e Time Machine local):"
df -h | awk '/^\/dev\/disk/ && $1 !~ /\/dev\/null/ { printf "  %-25s  used=%s  avail=%s  %s\n", $1, $3, $4, $9 }'

}

disk_overview_linux() {

# Só filesystems reais: fora tmpfs/devtmpfs (RAM), squashfs (cada snap montado
# aparece como um device) e overlay (containers).
df -hT -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs -x fuse.gvfsd-fuse 2>/dev/null \
  | awk 'NR==1 { printf "  %s\n", $0; next } !seen[$1]++ { printf "  %s\n", $0 }'

out ""
fs_summary / "Raiz (/)"

# $HOME em filesystem separado (/home dedicado é comum) → mostra os dois
home_fs=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print $1}')
root_fs=$(df -Pk / 2>/dev/null | awk 'NR==2 {print $1}')
if [[ -n "$home_fs" && "$home_fs" != "$root_fs" ]]; then
  fs_summary "$HOME" "\$HOME"
fi

# /boot cheio é o clássico "apt upgrade falhou" — quase sempre kernel antigo
if [[ "$(df -Pk /boot 2>/dev/null | awk 'NR==2 {print $6}')" == "/boot" ]]; then
  fs_summary /boot "/boot"
  boot_pct=$(df -Pk /boot 2>/dev/null | awk 'NR==2 { gsub(/%/, "", $5); print $5 }')
  if [[ "${boot_pct:-0}" -ge 80 ]]; then
    out "  ${C_YELLOW}⚠ /boot em ${boot_pct}% — kernels antigos costumam ser a causa;"
    out "    veja a seção 'Sistema' mais abaixo.${C_RESET}"
  fi
fi

root_fstype=$(df -PT / 2>/dev/null | awk 'NR==2 {print $2}')
case "$root_fstype" in
  btrfs|zfs)
    note "  Raiz em ${root_fstype}: snapshots dividem espaço com os arquivos vivos —"
    note "  apagar arquivo não libera nada enquanto um snapshot ainda o referenciar."
    ;;
  ext4)
    # Disco quase cheio + reserva grande: baixar pra 1% devolve espaço ao usuário
    read -r r_dev r_size r_used r_avail <<< "$(df -Pk / 2>/dev/null | awk 'NR==2 {print $1, $2, $3, $4}')"
    r_reserved=$(( ${r_size:-0} - ${r_used:-0} - ${r_avail:-0} ))
    r_gain=$(( r_reserved - ${r_size:-0} / 100 ))   # reserva atual - 1%
    if [[ $r_gain -ge 1048576 && $(( ${r_used:-0} * 100 / (${r_used:-0} + ${r_avail:-0} + 1) )) -ge 80 ]]; then
      r_pct=$(( (r_reserved * 100 + r_size / 2) / r_size ))
      out "  ${C_YELLOW}Dica:${C_RESET} o ext4 da raiz reserva $(human_bytes $((r_reserved * 1024))) só pro root. Com 1% sobra o bastante:"
      out "    ${C_BOLD}sudo tune2fs -m 1 $r_dev${C_RESET}   ${C_DIM}# libera ~$(human_bytes $((r_gain * 1024))) pro usuário${C_RESET}"
      shell_safe "$r_dev" && register_tip $((r_gain * 1024)) "Reserva do ext4 pro root na raiz: ${r_pct}% → 1%" \
        "sudo tune2fs -m 1 $r_dev  # devolve espaço ao usuário; desfaz com: sudo tune2fs -m ${r_pct} $r_dev"
    fi
    ;;
esac

# Swapfile: ocupa o disco sem aparecer em pasta nenhuma
sw_any=0
while read -r sw_name sw_type sw_size sw_used; do
  [[ "$sw_type" == file ]] || continue
  [[ $sw_any -eq 0 ]] && out ""
  sw_any=1
  out "  Swapfile ${sw_name}: $(human_bytes "${sw_size:-0}") (em uso: $(human_bytes "${sw_used:-0}"))"
done < <(swapon --show=NAME,TYPE,SIZE,USED --noheadings --bytes 2>/dev/null)
[[ $sw_any -eq 1 ]] && note "  Só vale reduzir se a RAM sobra com folga (veja 'free -h')."

}

# --- Raiz: para onde foi o espaço (Linux) -------------------------------------

# Filhos de um diretório no mesmo filesystem da raiz (sem symlinks e sem
# mounts como /proc, /boot ou /media)
# root_children <dir> <device da raiz>
root_children() {
  find "$1" -mindepth 1 -maxdepth 1 -printf '%D\t%y\t%p\n' 2>/dev/null \
    | awk -F'\t' -v dev="$2" '$1 == dev && $2 != "l" { print $3 }'
}

# Anotação curta pras pastas conhecidas do mapa da raiz
root_leaf_note() {
  case "$1" in
    "$HOME")                             echo "sua home — detalhada nas seções abaixo" ;;
    /usr)                                echo "programas instalados — maiores pacotes na seção Sistema" ;;
    /var/lib/docker|/var/lib/containerd) echo "Docker" ;;
    /var/lib/containers)                 echo "Podman" ;;
    /var/lib/snapd)                      echo "snaps — detalhado na seção Sistema" ;;
    /var/lib/flatpak)                    echo "Flatpak" ;;
    /var/log)                            echo "logs" ;;
    /var/cache)                          echo "caches do sistema" ;;
    /home/linuxbrew)                     echo "Homebrew" ;;
    /root)                               echo "home do root" ;;
    *) printf '%s\n' "$ROOT_SWAPS" | grep -qxF -- "$1" && echo "swap" ;;
  esac
  return 0
}

root_map_linux() {

section "Raiz (/) — para onde foi o espaço"
# Mede o filesystem da raiz por pasta e fecha a conta com o "em uso" do df.
# Pastas que só agrupam coisas sem relação descem um nível (/var/lib, dois),
# senão /var ou /home escondem o Docker, o snapd e o Homebrew.
rm_dev=$(stat -c %d / 2>/dev/null)
ROOT_SWAPS=$(swapon --show=NAME,TYPE --noheadings 2>/dev/null | awk '$2 == "file" {print $1}')
rm_leaves=()
rm_locked=""   # pastas que o usuário não lê: o du mediria só 4 KB
rm_queue=$(root_children / "$rm_dev")
while [[ -n "$rm_queue" ]]; do
  rm_next=""
  while IFS= read -r e; do
    [[ -n "$e" && "$e" != /lost+found ]] || continue
    case "$e" in
      /home|/opt|/var|/var/lib) rm_next+="$(root_children "$e" "$rm_dev")"$'\n' ;;
      *)
        if [[ -d "$e" && ( ! -r "$e" || ! -x "$e" ) ]]; then
          rm_locked+="$e"$'\n'
        else
          rm_leaves+=("$e")
        fi ;;
    esac
  done <<< "$rm_queue"
  rm_queue="$rm_next"
done
[[ ${#rm_leaves[@]} -gt 0 ]] || return 0

# Um du só: hardlinks (ex.: cache do snapd) contam uma vez
rm_du=$(run_spun "medindo a raiz (/)... (pode demorar)" du -xsk "${rm_leaves[@]}" 2>/dev/null)
sort -rn <<< "$rm_du" | head -n "$TOP_N" \
  | while IFS=$'\t' read -r kb p; do
      [[ -n "$kb" ]] || continue
      rm_note=$(root_leaf_note "$p")
      printf '  %8s  %s%s\n' "$(human_bytes $((kb * 1024)))" "$p" \
        "${rm_note:+  ${C_DIM}($rm_note)${C_RESET}}"
    done

# Ilegíveis: só as conhecidas ganham linha; o resto vira contagem
rm_locked_other=0
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  rm_note=$(root_leaf_note "$p")
  if [[ -n "$rm_note" ]]; then
    printf '  %8s  %s  %s(%s — só root lê)%s\n' "?" "$p" "$C_DIM" "$rm_note" "$C_RESET"
  else
    rm_locked_other=$((rm_locked_other + 1))
  fi
done <<< "$rm_locked"
[[ $rm_locked_other -gt 0 ]] && note "         +${rm_locked_other} pasta(s) do sistema que só root lê"

rm_measured_kb=$(awk -F'\t' '{s += $1} END {print s+0}' <<< "$rm_du")
rm_used_kb=$(df -Pk / 2>/dev/null | awk 'NR==2 {print $3}')
rm_gap_kb=$(( ${rm_used_kb:-0} - rm_measured_kb ))
out ""
out "  ${C_BOLD}Medido: $(human_bytes $((rm_measured_kb * 1024))) de $(human_bytes $(( ${rm_used_kb:-0} * 1024 ))) em uso no /${C_RESET}"
# Abaixo de 1 GB a diferença é ruído (metadados, arquivos mudando durante o du)
[[ $rm_gap_kb -ge 1048576 ]] || return 0
if [[ $EUID -ne 0 ]]; then
  out "  ${C_YELLOW}Faltam $(human_bytes $((rm_gap_kb * 1024))): pastas que só root lê (as marcadas com ? e partes de outras).${C_RESET}"
  if command -v docker >/dev/null 2>&1; then
    rm_docker=$(container_df_bytes docker Size)
    [[ ${rm_docker:-0} -gt 0 ]] && \
      note "  O Docker declara $(human_bytes "$rm_docker") no 'docker system df' — costuma ser a maior parte."
  fi
  note "  Pra fechar a conta (segue read-only): sudo HOME=\"$HOME\" $0"
  register_blind "$(human_bytes $((rm_gap_kb * 1024))) da raiz estão em pastas que só root lê (Docker, /root, journal) — pra contar: sudo HOME=\"$HOME\" $0"
else
  out "  ${C_YELLOW}Faltam $(human_bytes $((rm_gap_kb * 1024))) que nenhuma pasta explica.${C_RESET}"
  note "  Arquivos apagados que algum processo ainda mantém abertos (o espaço só volta quando ele fecha):"
  out "    ${C_BOLD}sudo lsof -nP +L1 | awk 'NR == 1 || \$7 > 104857600'${C_RESET}   ${C_DIM}# >100 MB; reinicie o processo${C_RESET}"
  note "  Ou arquivos escondidos sob um ponto de montagem (gravados antes de o disco ser montado)."
  register_tip 0 "$(human_bytes $((rm_gap_kb * 1024))) em uso que nenhuma pasta explica: arquivos apagados ainda abertos?" \
    "sudo lsof -nP +L1 | awk 'NR == 1 || \$7 > 104857600'  # só lista; o espaço volta ao reiniciar o processo que segura o arquivo"
fi

}

# --- Snapshots locais ---------------------------------------------------------

# Corpos de section_if: não imprimem nada quando não há snapshot

snapshots_macos() {

if command -v tmutil >/dev/null 2>&1; then
  snaps=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c "com.apple.TimeMachine" || true)
  if [[ "$snaps" -gt 0 ]]; then
    note "(Costumam ser invisíveis ao Finder mas ocupam GB)"
    out "  ${C_YELLOW}${snaps} snapshot(s) local(is) encontrado(s)${C_RESET}"
    tmutil listlocalsnapshots / 2>/dev/null | sed 's/^/    /'
    out ""
    out "  ${C_GREEN}Para remover os mais antigos (libera GBs):${C_RESET}"
    out "    ${C_BOLD}sudo tmutil thinlocalsnapshots / 999999999999 4${C_RESET}"
    register_tip 0 "${snaps} snapshot(s) local(is) do Time Machine (tamanho não informado)" \
      "sudo tmutil thinlocalsnapshots / 999999999999 4  # o macOS também apaga sozinho quando o disco aperta"
  fi
fi

}

snapshots_linux() {

snap_found=0

# ZFS — instalação padrão do Ubuntu com "Erase disk and use ZFS" cria
# snapshots automáticos a cada apt upgrade (zsys); acumulam dezenas de GB.
if command -v zfs >/dev/null 2>&1; then
  zfs_bytes=$(zfs list -H -p -t snapshot -o used 2>/dev/null | awk '{s+=$1} END {print s+0}')
  zfs_count=$(zfs list -H -t snapshot -o name 2>/dev/null | grep -c . || true)
  if [[ "${zfs_count:-0}" -gt 0 ]]; then
    snap_found=1
    out "  ${C_YELLOW}${zfs_count} snapshot(s) ZFS — $(human_bytes "${zfs_bytes:-0}") no total${C_RESET}"
    zfs list -H -t snapshot -o name,used -s used 2>/dev/null | tail -10 \
      | awk -F'\t' '{ printf "    %8s  %s\n", $2, $1 }'
    out ""
    out "  ${C_GREEN}Para inspecionar e apagar:${C_RESET}"
    out "    ${C_BOLD}zfs list -t snapshot -o name,used -s used${C_RESET}"
    out "    ${C_BOLD}sudo zfs destroy <dataset>@<snapshot>${C_RESET}   ${C_DIM}# um por vez${C_RESET}"
    command -v zsysctl >/dev/null 2>&1 && \
      out "    ${C_BOLD}sudo zsysctl state remove <estado>${C_RESET}       ${C_DIM}# estados criados pelo zsys${C_RESET}"
    register_opp "${zfs_bytes:-0}" "REVISAR" "" \
      "${zfs_count} snapshot(s) ZFS" \
      "sudo zfs destroy <dataset>@<snap>  # perde o rollback pra esse ponto"
  fi
fi

# Timeshift — backup do sistema; apagar snapshot é perder ponto de restauração
if command -v timeshift >/dev/null 2>&1; then
  for ts_dir in /timeshift /run/timeshift/backup/timeshift; do
    [[ -d "$ts_dir" ]] || continue
    ts_kb=$(du -sk "$ts_dir" 2>/dev/null | awk '{print $1}')
    ts_bytes=$(( ${ts_kb:-0} * 1024 ))
    snap_found=1
    out ""
    note "Timeshift:"
    if [[ $ts_bytes -gt 0 ]]; then
      printf '  %8s  %s\n' "$(human_bytes "$ts_bytes")" "$ts_dir"
      register_opp "$ts_bytes" "REVISAR" "$ts_dir" "Snapshots do Timeshift" \
        "# liste com 'sudo timeshift --list' e apague um por vez: sudo timeshift --delete --snapshot '<data>'"
    else
      note "  $ts_dir existe mas não é legível sem sudo (rode 'sudo timeshift --list')"
    fi
  done
fi

# Btrfs — listar subvolumes exige root; só aponta o caminho
if [[ "$(df -PT / 2>/dev/null | awk 'NR==2 {print $2}')" == "btrfs" ]]; then
  snap_found=1
  note "  Raiz em Btrfs — liste os snapshots com:"
  out "    ${C_BOLD}sudo btrfs subvolume list -s /${C_RESET}"
  out "    ${C_BOLD}sudo btrfs filesystem usage /${C_RESET}   ${C_DIM}# quanto realmente sobra${C_RESET}"
fi

[[ $snap_found -eq 1 ]] && note "  (Snapshots ocupam espaço sem aparecer no gerenciador de arquivos)"
return 0

}

# --- Sandboxes / apps empacotados --------------------------------------------

containers_macos() {

section "~/Library/Containers — top $TOP_N"
run_spun "escaneando ~/Library/Containers... (pode demorar bastante)" top_children_register "$HOME/Library/Containers" "$TOP_N" "REVISAR" "Container" '# limpar pelo app correspondente a {}'

}

containers_linux() {

# Flatpak e snap guardam dados por app fora do padrão XDG
flatpak_dir="$HOME/.var/app"
snap_dir="$HOME/snap"
[[ -d "$flatpak_dir" || -d "$snap_dir" ]] || return 0

section "Dados de apps Flatpak/Snap — top $TOP_N"
if [[ -d "$flatpak_dir" ]]; then
  note "~/.var/app (Flatpak):"
  run_spun "escaneando ~/.var/app..." top_children_register "$flatpak_dir" "$TOP_N" "REVISAR" "Flatpak" '# dados do app; limpe pelo próprio app ou: flatpak uninstall <app>'
  out ""
fi
if [[ -d "$snap_dir" ]]; then
  note "~/snap (dados por revisão de snap):"
  run_spun "escaneando ~/snap..." top_children_register "$snap_dir" "$TOP_N" "REVISAR" "Snap (dados)" '# dados do snap; some ao remover o snap: sudo snap remove <nome>'
  out ""
  note "  Caches dos snaps ficam em ~/snap/<app>/common/.cache — costumam ser descartáveis."
fi

}

# --- Sistema (Linux): pacotes, logs e crashes ---------------------------------

section_linux_system() {

section "Sistema — pacotes, logs e crashes"

# Cache do gerenciador de pacotes
case "$PKG" in
  apt)
    sys_report_dir /var/cache/apt/archives "SEGURO" \
      "Cache do apt (.deb baixados)" "sudo apt-get clean"
    sys_report_dir /var/lib/apt/lists "MODERADO" \
      "Índices do apt (/var/lib/apt/lists)" \
      "sudo rm -rf /var/lib/apt/lists/*  # 'sudo apt update' baixa de novo"
    ;;
  dnf)
    sys_report_dir /var/cache/dnf "SEGURO" "Cache do dnf" "sudo dnf clean all" ;;
  pacman)
    sys_report_dir /var/cache/pacman/pkg "SEGURO" "Cache do pacman" \
      "sudo paccache -rk1  # mantém a última versão de cada pacote" ;;
esac

# Pacotes órfãos e kernels antigos: pergunta ao próprio apt (simulação roda
# sem root). Somar os linux-* do dpkg superestima: pacotes já removidos com
# config residual (rc) continuam listados com o tamanho antigo, e o apt
# sempre preserva o kernel em uso e o anterior.
if [[ "$PKG" == apt ]] && command -v dpkg-query >/dev/null 2>&1; then
  autorm_pkgs=$(apt-get -s autoremove 2>/dev/null | awk '/^Remv / {print $2}')
  if [[ -n "$autorm_pkgs" ]]; then
    # shellcheck disable=SC2086  # nomes de pacote não têm espaço
    read -r autorm_count autorm_kb autorm_kern <<< "$(dpkg-query -W -f='${Package}\t${Installed-Size}\n' \
        $autorm_pkgs 2>/dev/null \
      | awk -F'\t' '{ n++; kb += $2 } $1 ~ /^linux-(image|modules|headers)-/ { k++ }
                    END { printf "%d %d %d\n", n+0, kb+0, k+0 }')"
    printf '  %8s  %s\n' "$(human_bytes $(( ${autorm_kb:-0} * 1024 )))" \
      "${autorm_count} pacote(s) órfão(s) no apt autoremove (${autorm_kern} de kernel antigo)"
    register_opp $(( ${autorm_kb:-0} * 1024 )) "SEGURO" "" \
      "apt autoremove (${autorm_count} pacotes, ${autorm_kern} de kernel)" \
      "sudo apt autoremove --purge  # preserva o kernel em uso e o anterior"
  fi

  # Maiores pacotes instalados: o /usr costuma ser o maior bloco fora da home.
  # Só 'ii' (os 'rc' guardam o tamanho antigo); kernels ficam de fora, o
  # autoremove acima já cuida dos antigos. Informativo: não entra no ranking.
  pkg_top=$(dpkg-query -W -f='${db:Status-Abbrev}\t${Installed-Size}\t${Package}\n' 2>/dev/null \
    | awk -F'\t' '$1 == "ii " && $3 !~ /^linux-(image|modules|headers)-/ { print $2 "\t" $3 }' \
    | sort -rn | head -n 8)
  if [[ -n "$pkg_top" ]]; then
    note "  Maiores pacotes instalados (os que você não usa: sudo apt remove <pacote>):"
    while IFS=$'\t' read -r kb name; do
      printf '  %8s    ↳ %s\n' "$(human_bytes $((kb * 1024)))" "$name"
    done <<< "$pkg_top"
  fi
fi

if command -v snap >/dev/null 2>&1; then
  # Snaps instalados: cada um é um .snap (squashfs) inteiro em
  # /var/lib/snapd/snaps, legível sem root. Só sai removendo o app.
  snap_inst=$(snap list 2>/dev/null | awk 'NR > 1 { print $1 "\t" $1 "_" $3 ".snap" }' \
    | while IFS=$'\t' read -r n f; do
        [[ -e "/var/lib/snapd/snaps/$f" ]] || continue
        printf '%s\t%s\n' "$(du -k "/var/lib/snapd/snaps/$f" 2>/dev/null | cut -f1)" "$n"
      done \
    | sort -rn)
  if [[ -n "$snap_inst" ]]; then
    read -r si_n si_kb <<< "$(awk -F'\t' '{ n++; s += $1 } END { print n+0, s+0 }' <<< "$snap_inst")"
    si_top=$(head -3 <<< "$snap_inst" | while IFS=$'\t' read -r kb n; do
               printf '%s %s, ' "$n" "$(human_bytes $((kb * 1024)))"
             done)
    printf '  %8s  %s\n' "$(human_bytes $(( ${si_kb:-0} * 1024 )))" \
      "${si_n} snap(s) instalado(s) — maiores: ${si_top%, }"
  fi

  # Revisões desativadas ficam no disco inteiras (o snap é um squashfs)
  snap_disabled=$(snap list --all 2>/dev/null \
    | awk 'NR > 1 && $NF ~ /disabled/ { print $1 "_" $3 ".snap" }')
  if [[ -n "$snap_disabled" ]]; then
    snap_count=$(printf '%s\n' "$snap_disabled" | grep -c . || true)
    snap_kb=$(printf '%s\n' "$snap_disabled" \
      | while IFS= read -r f; do
          [[ -e "/var/lib/snapd/snaps/$f" ]] && du -sk "/var/lib/snapd/snaps/$f" 2>/dev/null
        done \
      | awk '{s+=$1} END {print s+0}')
    printf '  %8s  %s\n' "$(human_bytes $(( ${snap_kb:-0} * 1024 )))" \
      "${snap_count} revisão(ões) de snap desativada(s)"
    # O snap remove não libera nada sozinho: o .snap da revisão continua no
    # cache de download do snapd (agora sem outro link) até ser apagado
    register_opp $(( ${snap_kb:-0} * 1024 )) "SEGURO" "" \
      "Revisões desativadas de snap (${snap_count})" \
      "snap list --all | awk '/disabled/{print \$1, \$3}' | while read -r n r; do sudo snap remove \"\$n\" --revision=\"\$r\"; done; sudo find /var/lib/snapd/cache -type f -links 1 -delete  # o .snap removido fica no cache do snapd"
    # O snapd guarda refresh.retain revisões (padrão e mínimo: 2, a atual + 1)
    snap_retain=$(snap get system refresh.retain 2>/dev/null || true)
    if [[ "$snap_retain" =~ ^[0-9]+$ && "$snap_retain" -gt 2 ]]; then
      note "  Pra acumular menos: sudo snap set system refresh.retain=2 (hoje: $snap_retain)"
      register_tip 0 "Snap guarda $snap_retain revisões de cada app; 2 bastam" \
        "sudo snap set system refresh.retain=2  # a atual + uma pra voltar"
    fi
  fi
  # O cache de download é hardlink dos .snap instalados: só libera espaço o
  # arquivo que não tem outro link (sobra de revisão já removida). Sem root
  # o find não entra na pasta — avisa em vez de dar zero calado.
  if [[ -d /var/lib/snapd/cache && ! -r /var/lib/snapd/cache ]]; then
    printf '  %8s  %s  %s(downloads sem snap instalado; só root lê)%s\n' "?" "/var/lib/snapd/cache" "$C_DIM" "$C_RESET"
  else
    snapc_kb=$(find /var/lib/snapd/cache -type f -links 1 -exec du -k {} + 2>/dev/null \
      | awk '{s+=$1} END {print s+0}')
    if [[ "${snapc_kb:-0}" -gt 0 ]]; then
      printf '  %8s  %s\n' "$(human_bytes $((snapc_kb * 1024)))" "/var/lib/snapd/cache (downloads sem snap instalado)"
      register_opp $((snapc_kb * 1024)) "SEGURO" "/var/lib/snapd/cache" "Cache de download do snapd" \
        "sudo find /var/lib/snapd/cache -type f -links 1 -delete  # o resto é hardlink de snap instalado"
    fi
  fi

  # Seed: os snaps que vieram na imagem de instalação. Não há comando oficial
  # pra limpar — só informação, fora do ranking.
  seed_kb=$(du -sk /var/lib/snapd/seed 2>/dev/null | awk '{print $1}')
  if [[ "${seed_kb:-0}" -ge 1024 ]]; then
    printf '  %8s  %s  %s(snaps da instalação; sem comando oficial pra limpar)%s\n' \
      "$(human_bytes $((seed_kb * 1024)))" "/var/lib/snapd/seed" "$C_DIM" "$C_RESET"
  fi
fi

# Flatpak: runtimes órfãos depois de desinstalar apps
if command -v flatpak >/dev/null 2>&1; then
  sys_report_dir /var/lib/flatpak "MODERADO" "Flatpak (apps + runtimes do sistema)" \
    "flatpak uninstall --unused  # remove runtimes que nenhum app usa"
fi

# Journal do systemd
if command -v journalctl >/dev/null 2>&1; then
  ju_line=$(journalctl --disk-usage 2>/dev/null | tail -1)
  ju_size=$(printf '%s' "$ju_line" | grep -oE '[0-9]+([.,][0-9]+)?[KMGT]i?B?' | tail -1)
  if [[ -n "${ju_size:-}" ]]; then
    ju_bytes=$(parse_size_to_bytes "${ju_size//,/.}")
    printf '  %8s  %s\n' "$(human_bytes "${ju_bytes:-0}")" "journal do systemd (logs do sistema)"
    register_opp "${ju_bytes:-0}" "SEGURO" "" "Journal do systemd" \
      "sudo journalctl --vacuum-size=200M  # ou --vacuum-time=7d"
    if grep -qsE '^[[:space:]]*SystemMaxUse=' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf; then
      note "  ✓ Tamanho máximo configurado (SystemMaxUse)"
    else
      note "  Sem limite configurado. Limite permanente:"
      note "    sudo mkdir -p /etc/systemd/journald.conf.d"
      note "    printf '[Journal]\\\\nSystemMaxUse=500M\\\\n' | sudo tee /etc/systemd/journald.conf.d/size.conf"
      note "    sudo systemctl restart systemd-journald"
      register_tip 0 "Journal do systemd sem limite de tamanho: limitar a 500 MB" \
        "sudo mkdir -p /etc/systemd/journald.conf.d && printf '[Journal]\\nSystemMaxUse=500M\\n' | sudo tee /etc/systemd/journald.conf.d/size.conf >/dev/null && sudo systemctl restart systemd-journald"
    fi
  fi
fi

# /var/log fora do journal: total + arquivos gigantes um a um. Um app em loop
# de erro enche o syslog em horas, e o rotacionado (.1) só é comprimido na
# rotação seguinte.
if [[ -d /var/log ]]; then
  vlog_kb=$(du -sk --exclude=journal /var/log 2>/dev/null | awk '{print $1}')
  vlog_bytes=$(( ${vlog_kb:-0} * 1024 ))
  if [[ $vlog_bytes -gt 0 ]]; then
    printf '  %8s  %s\n' "$(human_bytes "$vlog_bytes")" "/var/log (sem o journal)"
    vlog_big=$(find /var/log -path /var/log/journal -prune -o -type f -size +100M -exec du -k {} + 2>/dev/null \
      | sort -rn | head -n "$TOP_N")
    while IFS=$'\t' read -r kb f; do
      [[ -n "$kb" && -n "$f" ]] || continue
      printf '  %8s    ↳ %s\n' "$(human_bytes $((kb * 1024)))" "$f"
      if [[ "$f" =~ \.[0-9]+(\.(gz|xz|zst))?$ || "$f" =~ -[0-9]{8}(\.(gz|xz|zst))?$ || "$f" =~ \.(gz|xz|zst|old)$ ]]; then
        register_opp $((kb * 1024)) "SEGURO" "$f" "Log rotacionado: $(basename "$f")" \
          "sudo rm -f \"$f\"  # já saiu de uso"
      else
        register_opp $((kb * 1024)) "MODERADO" "$f" "Log ativo: $(basename "$f")" \
          "sudo truncate -s 0 \"$f\"  # e descubra quem está escrevendo tanto"
      fi
    done <<< "$vlog_big"
    if [[ -n "$vlog_big" ]]; then
      note "  Quem encheu? sudo awk '{sub(/\\\\[.*/, \"\", \$3); print \$3}' <arquivo> | sort | uniq -c | sort -rn | head"
    fi
  fi
fi

# Crashes: core dumps do systemd e relatórios do apport (Ubuntu)
sys_report_dir /var/lib/systemd/coredump "SEGURO" "Core dumps do systemd" \
  "sudo rm -f /var/lib/systemd/coredump/*  # limite em /etc/systemd/coredump.conf"
sys_report_dir /var/crash "SEGURO" "Relatórios de crash do apport" \
  "sudo rm -f /var/crash/*"
sys_report_dir /var/tmp "MODERADO" "/var/tmp (temporários que sobrevivem a reboot)" \
  "# revise antes: sudo ls -lhS /var/tmp | head"

# Ferramentas rodadas com sudo deixam cache na home do root (go build, pip...)
sys_report_dir /root/.cache "SEGURO" "Cache do root (/root/.cache)" \
  "sudo rm -rf /root/.cache/*  # regenera"
sys_report_dir /root/go/pkg/mod "MODERADO" "Módulos Go do root (/root/go/pkg/mod)" \
  "sudo rm -rf /root/go/pkg/mod  # baixam de novo no próximo 'sudo go build'"

if [[ $EUID -ne 0 ]] && ! system_dirs_readable; then
  out ""
  note "  Alguns diretórios acima só são legíveis como root — os números podem estar baixos."
fi

}

# --- Navegadores --------------------------------------------------------------

section_browsers_linux() {

# cache|perfil|nome|processo|pasta de políticas — só entra na lista quem existe
# na máquina. Processo com '/' é casado contra a linha de comando (pgrep -f): o
# Chromium do snap roda como "chrome", mesmo nome do Google Chrome.
br_entries=(
  "$CACHE_DIR/google-chrome|$HOME/.config/google-chrome|Google Chrome|chrome|/etc/opt/chrome/policies/managed"
  "$CACHE_DIR/chromium|$HOME/.config/chromium|Chromium|chromium|/etc/chromium/policies/managed"
  "$CACHE_DIR/BraveSoftware|$HOME/.config/BraveSoftware|Brave|brave|/etc/brave/policies/managed"
  "$CACHE_DIR/microsoft-edge|$HOME/.config/microsoft-edge|Microsoft Edge|msedge|/etc/opt/edge/policies/managed"
  "$CACHE_DIR/vivaldi|$HOME/.config/vivaldi|Vivaldi|vivaldi|"
  "$CACHE_DIR/mozilla|$HOME/.mozilla|Firefox|firefox|"
  "$HOME/snap/firefox/common/.cache/mozilla|$HOME/snap/firefox|Firefox (snap)|firefox|"
  "$HOME/snap/chromium/common/.cache/chromium|$HOME/snap/chromium/common/chromium|Chromium (snap)|^/snap/chromium/[^ ]*/chrome|/etc/chromium-browser/policies/managed"
  "$HOME/.var/app/org.mozilla.firefox/cache|$HOME/.var/app/org.mozilla.firefox|Firefox (Flatpak)|firefox|"
)

br_any=0
br_policy_dirs=""   # pastas de política dos navegadores Chromium listados
for br_entry in "${br_entries[@]}"; do
  IFS='|' read -r br_cache br_profile br_name br_proc br_policy <<< "$br_entry"
  [[ -d "$br_cache" || -d "$br_profile" ]] || continue
  br_lines=""   # só mostra o navegador se houver algo pra limpar

  if [[ -d "$br_cache" ]]; then
    br_kb=$(run_spun "medindo cache do ${br_name}..." du -sk "$br_cache" 2>/dev/null | awk '{print $1}')
    br_bytes=$(( ${br_kb:-0} * 1024 ))
    if [[ $br_bytes -gt 0 ]]; then
      br_lines+="$(printf '  %8s  %s' "$(human_bytes "$br_bytes")" "cache HTTP/código ($(tilde "$br_cache"))")"$'\n'
      register_opp "$br_bytes" "SEGURO" "$br_cache" "${br_name}: cache HTTP/código" \
        "rm -rf \"$br_cache\"  # com o navegador fechado; regenera navegando"
    fi
  fi

  if [[ -d "$br_profile" && "$br_proc" != firefox ]]; then
    # Com --user-data-dir fora do ~/.config (o snap usa ~/snap/chromium/common)
    # o Chromium grava o cache HTTP dentro de cada perfil, não no ~/.cache
    pc_kb=$(du -sk "$br_profile"/*/Cache "$br_profile"/*/"Code Cache" "$br_profile"/*/GPUCache 2>/dev/null \
      | awk '{s+=$1} END {print s+0}')
    pc_bytes=$(( ${pc_kb:-0} * 1024 ))
    if [[ $pc_bytes -gt 0 ]]; then
      br_lines+="$(printf '  %8s  %s' "$(human_bytes "$pc_bytes")" "cache HTTP/código dentro dos perfis (Cache, Code Cache, GPUCache)")"$'\n'
      # path-chave próprio: com o do perfil inteiro, o dedup do ranking
      # engoliria a linha dos PWAs (ou esta)
      register_opp "$pc_bytes" "SEGURO" "$br_profile/*/Cache" "${br_name}: cache HTTP/código dos perfis" \
        "rm -rf \"$br_profile\"/*/Cache \"$br_profile\"/*/\"Code Cache\" \"$br_profile\"/*/GPUCache  # navegador fechado; regenera navegando"
    fi

    # PWAs (Service Worker), somando perfis
    sw_kb=$(du -sk "$br_profile"/*/"Service Worker/CacheStorage" 2>/dev/null | awk '{s+=$1} END {print s+0}')
    sw_bytes=$(( ${sw_kb:-0} * 1024 ))
    if [[ $sw_bytes -gt 0 ]]; then
      br_lines+="$(printf '  %8s  %s' "$(human_bytes "$sw_bytes")" "cache offline de PWAs (Service Worker, todos os perfis)")"$'\n'
      register_opp "$sw_bytes" "MODERADO" "$br_profile/*/Service Worker/CacheStorage" "${br_name}: cache offline de PWAs" \
        "rm -rf \"$br_profile\"/*/\"Service Worker/CacheStorage\"  # navegador fechado; PWAs re-baixam"
    fi
  fi

  [[ -n "$br_lines" ]] || continue
  if [[ $br_any -eq 0 ]]; then
    section "Navegadores — caches gerenciáveis"
    br_any=1
  fi
  out "  ${C_BOLD}${br_name}${C_RESET}"
  printf '%s' "$br_lines"
  if [[ "$br_proc" == */* ]]; then br_pgrep=(pgrep -f "$br_proc"); else br_pgrep=(pgrep -x "$br_proc"); fi
  if "${br_pgrep[@]}" >/dev/null 2>&1; then
    note "  ⚠ ${br_name} está aberto — os comandos rm acima exigem o app fechado."
  fi
  out ""
  [[ -n "$br_policy" ]] && br_policy_dirs+="$br_name|$br_policy"$'\n'
done

[[ $br_any -eq 1 ]] || return 0

# Política DiskCacheSize: o Chromium passa a se auto-limpar em vez de crescer.
# Cada navegador lê a sua pasta — a do Chrome não vale pro Chromium do snap.
while IFS='|' read -r br_name br_policy; do
  [[ -n "$br_policy" ]] || continue
  br_policy_file=$(grep -lsr DiskCacheSize "$br_policy" 2>/dev/null | head -1)
  if [[ -n "$br_policy_file" ]]; then
    out "  ${C_GREEN}✓ Cache do ${br_name} limitado por política${C_RESET} ${C_DIM}($br_policy_file)${C_RESET}"
  else
    out "  ${C_YELLOW}Dica:${C_RESET} limite o cache do ${br_name} de forma permanente (o navegador passa a se auto-limpar):"
    out "    ${C_BOLD}sudo mkdir -p $br_policy${C_RESET}"
    out "    ${C_BOLD}echo '{\"DiskCacheSize\": 2147483648}' | sudo tee $br_policy/hogspot.json${C_RESET}  ${C_DIM}# 2 GB${C_RESET}"
    register_tip 0 "Limitar o cache do ${br_name} a 2 GB (ele passa a se auto-limpar)" \
      "sudo mkdir -p $br_policy && echo '{\"DiskCacheSize\": 2147483648}' | sudo tee $br_policy/hogspot.json >/dev/null  # vale ao reabrir o navegador"
  fi
done <<< "$br_policy_dirs"
note "  (Perfis, extensões, IndexedDB e Local Storage são dados de sites — ficam de fora.)"

}

# --- Xcode / iOS (macOS) ------------------------------------------------------

# Corpo de section_if: sem ~/Library/Developer, não imprime nada
section_dev_xcode() {

if [[ -d "$HOME/Library/Developer" ]]; then
  for sub in Xcode/DerivedData Xcode/Archives Xcode/iOS\ DeviceSupport \
             Xcode/macOS\ DeviceSupport CoreSimulator/Devices \
             CoreSimulator/Caches XCTestDevices; do
    p="$HOME/Library/Developer/$sub"
    if [[ -e "$p" ]]; then
      bs=$(run_spun "medindo $sub..." du -sk "$p" 2>/dev/null | awk '{print $1*1024}')
      sz=$(human_bytes "${bs:-0}")
      printf "  %8s  %s\n" "$sz" "$p"

      # Comando + nível de risco por subdir
      case "$sub" in
        Xcode/DerivedData)
          risk=SEGURO;   cmd='rm -rf "$HOME/Library/Developer/Xcode/DerivedData"/*' ;;
        Xcode/Archives)
          risk=REVISAR;  cmd='# Xcode → Window → Organizer → apagar archives antigos' ;;
        Xcode/iOS\ DeviceSupport|Xcode/macOS\ DeviceSupport)
          risk=MODERADO; cmd='# símbolos regeneram ao reconectar o device; ok apagar versões antigas' ;;
        CoreSimulator/Devices)
          risk=REVISAR;  cmd='xcrun simctl delete unavailable  # ou apagar pelo Xcode → Devices' ;;
        CoreSimulator/Caches)
          risk=SEGURO;   cmd='rm -rf "$HOME/Library/Developer/CoreSimulator/Caches"/*' ;;
        XCTestDevices)
          risk=MODERADO; cmd='xcrun simctl --set testing delete all  # sims efêmeros de teste' ;;
        *)
          risk=REVISAR;  cmd="# revisar manualmente: $p" ;;
      esac
      register_opp "${bs:-0}" "$risk" "$p" "Xcode/$sub" "$cmd"
    fi
  done

  # Preview de 'simctl delete unavailable': lista simuladores cujo runtime
  # foi removido (sobram só ocupando disco) e soma quanto eles ocupam.
  if command -v xcrun >/dev/null 2>&1 && xcrun simctl help >/dev/null 2>&1; then
    out ""
    unavail_list=$(run_spun "listando simuladores indisponíveis..." xcrun simctl list devices unavailable 2>/dev/null)
    unavail_udids=$(printf '%s\n' "$unavail_list" \
      | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' || true)

    unavail_count=0
    unavail_bytes=0
    unavail_names=""
    if [[ -n "$unavail_udids" ]]; then
      # Mede todos os simuladores indisponíveis numa tacada só (spinner único).
      # Saída por linha: <bytes>|<size_humano>|<nome>
      unavail_data=$(run_spun "medindo simuladores indisponíveis..." bash -c '
        unavail_list="$1"; shift
        home="$1"; shift
        while IFS= read -r udid; do
          [[ -z "$udid" ]] && continue
          dpath="$home/Library/Developer/CoreSimulator/Devices/$udid"
          [[ -d "$dpath" ]] || continue
          b=$(du -sk "$dpath" 2>/dev/null | awk "{print \$1*1024}")
          hsize=$(du -sh "$dpath" 2>/dev/null | awk "{print \$1}")
          name=$(printf "%s\n" "$unavail_list" | grep -m1 "$udid" \
            | sed -E "s/^[[:space:]]+//; s/ \([0-9A-F-]+\).*//")
          printf "%s|%s|%s\n" "${b:-0}" "${hsize:-?}" "$name"
        done
      ' _ "$unavail_list" "$HOME" <<< "$unavail_udids")

      while IFS='|' read -r b hsize name; do
        [[ -z "$b" ]] && continue
        unavail_bytes=$((unavail_bytes + b))
        unavail_count=$((unavail_count + 1))
        unavail_names+="    $(printf '%6s  %s' "$hsize" "$name")"$'\n'
      done <<< "$unavail_data"
    fi

    out "  ${C_BOLD}xcrun simctl delete unavailable${C_RESET} ${C_DIM}(preview):${C_RESET}"
    if [[ $unavail_count -gt 0 ]]; then
      out "  ${C_YELLOW}${unavail_count} simulador(es) indisponível(eis), $(human_bytes $unavail_bytes) total${C_RESET}"
      printf '%s' "$unavail_names"
      register_opp "$unavail_bytes" "SEGURO" "$HOME/Library/Developer/CoreSimulator/Devices" "${unavail_count} simulador(es) iOS indisponível(eis)" "xcrun simctl delete unavailable"
    else
      out "  ${C_GREEN}Nada pra limpar (nenhum simulador indisponível).${C_RESET}"
    fi
  fi

  # --- Runtimes do Simulator (em /Library, fora da home) ---
  # iOS/iPadOS/watchOS/tvOS runtimes ficam em /Library e podem ter 6-8 GB cada
  runtime_locations=(
    "/Library/Developer/CoreSimulator/Profiles/Runtimes"
    "/Library/Developer/CoreSimulator/Volumes"
  )
  has_any_runtime_dir=0
  for loc in "${runtime_locations[@]}"; do
    [[ -d "$loc" ]] && has_any_runtime_dir=1
  done

  if [[ $has_any_runtime_dir -eq 1 ]]; then
    out ""
    out "  ${C_BOLD}Runtimes do Simulator${C_RESET} ${C_DIM}(em /Library, fora da home):${C_RESET}"

    total_runtime_bytes=0
    for loc in "${runtime_locations[@]}"; do
      if [[ -d "$loc" ]]; then
        # Mede em KB com spinner (uma chamada só), depois deriva human-readable
        bs=$(run_spun "medindo $loc..." du -sk "$loc" 2>/dev/null | awk '{print $1*1024}')
        sz=$(human_bytes "${bs:-0}")
        total_runtime_bytes=$((total_runtime_bytes + ${bs:-0}))
        out "    $(printf '%8s' "$sz")  $loc"
        register_opp "${bs:-0}" "MODERADO" "$loc" "Simulator runtimes em $loc" "# Xcode → Settings → Platforms; ou 'xcrun simctl runtime delete <id>'"
      fi
    done

    # Lista runtimes individuais + extrai identifiers dos "unusable" pra montar comando
    if command -v xcrun >/dev/null 2>&1 && xcrun simctl help >/dev/null 2>&1; then
      runtime_list=$(run_spun "listando runtimes..." xcrun simctl runtime list 2>/dev/null)
      runtime_count=$(printf '%s\n' "$runtime_list" | grep -cE '^(iOS|iPadOS|watchOS|tvOS|visionOS) ' || true)

      # Extrai os identifiers (com.apple.CoreSimulator.SimRuntime.*) de linhas marcadas unusable
      unusable_ids=$(printf '%s\n' "$runtime_list" \
        | awk '/[Uu]nusable/ {
            if (match($0, /com\.apple\.CoreSimulator\.SimRuntime\.[A-Za-z0-9._-]+/)) {
              print substr($0, RSTART, RLENGTH)
            }
          }')
      unusable_count=$(printf '%s\n' "$unusable_ids" | grep -c . || true)

      if [[ ${runtime_count:-0} -gt 0 ]]; then
        out ""
        out "    ${C_DIM}${runtime_count} runtime(s) instalado(s):${C_RESET}"
        printf '%s\n' "$runtime_list" | grep -E '^(iOS|iPadOS|watchOS|tvOS|visionOS) ' \
          | sed 's/^/      /'
      fi

      out ""
      if [[ ${unusable_count:-0} -gt 0 ]]; then
        out "    ${C_YELLOW}${unusable_count} runtime(s) marcado(s) como 'unusable':${C_RESET}"
        while IFS= read -r id; do
          [[ -z "$id" ]] && continue
          out "      ${C_DIM}$id${C_RESET}"
        done <<< "$unusable_ids"
        out ""
        out "    ${C_GREEN}Apagar todos de uma vez:${C_RESET}"
        # Monta o comando real com os identifiers (delete aceita múltiplos args)
        ids_oneline=$(printf '%s ' $unusable_ids)
        out "      ${C_BOLD}xcrun simctl runtime delete ${ids_oneline}${C_RESET}"
      else
        out "    ${C_GREEN}Nenhum runtime 'unusable'.${C_RESET}"
      fi

      out ""
      out "    ${C_DIM}Outras formas de podar runtimes:${C_RESET}"
      out "      ${C_BOLD}xcrun simctl runtime list -v${C_RESET}                  ${C_DIM}# mostra identifier+estado de cada um${C_RESET}"
      out "      ${C_BOLD}xcrun simctl runtime delete <id>${C_RESET}              ${C_DIM}# apaga 1 runtime específico${C_RESET}"
      out "      ${C_BOLD}xcrun simctl runtime delete --notUsedSinceDays 30${C_RESET}  ${C_DIM}# apaga não-usados há 30+ dias${C_RESET}"
      out "    ${C_DIM}Ou pelo Xcode → Settings → Platforms${C_RESET}"
    fi
  fi

  out ""
  out "  ${C_GREEN}Comandos seguros (recap):${C_RESET}"
  out "    ${C_BOLD}rm -rf ~/Library/Developer/Xcode/DerivedData/*${C_RESET}"
  out "    ${C_BOLD}xcrun simctl delete unavailable${C_RESET}                       ${C_DIM}# simuladores sem runtime${C_RESET}"
  out "    ${C_BOLD}xcrun simctl runtime delete --notUsedSinceDays 30${C_RESET}     ${C_DIM}# runtimes parados há 30+ dias${C_RESET}"
fi

}

# Corpo de section_if: sem backups, não imprime nada
section_mobilesync() {

ms="$HOME/Library/Application Support/MobileSync/Backup"
if [[ -d "$ms" ]]; then
  ms_bytes=$(run_spun "medindo backups MobileSync... (podem ser dezenas de GB)" du -sk "$ms" 2>/dev/null | awk '{print $1*1024}')
  ms_size=$(human_bytes "${ms_bytes:-0}")
  out "  ${C_DIM}Total:${C_RESET} ${C_BOLD}${ms_size}${C_RESET}"
  out ""
  run_spun "listando backups individuais..." top_children "$ms" 10
  note "Apague pelo Finder → seu dispositivo → Gerenciar Backups."
  register_opp "${ms_bytes:-0}" "REVISAR" "$ms" "Backups iPhone/iPad (MobileSync)" "# Finder → seu dispositivo → Gerenciar Backups"
fi

}

section_browsers_macos() {

CHROME_CACHE="$HOME/Library/Caches/Google/Chrome"
CHROME_AS="$HOME/Library/Application Support/Google/Chrome"
if [[ -d "$CHROME_CACHE" || -d "$CHROME_AS" ]]; then
  section "Google Chrome — caches gerenciáveis"

  chrome_running=0
  pgrep -qx "Google Chrome" 2>/dev/null && chrome_running=1

  if [[ -d "$CHROME_CACHE" ]]; then
    bs=$(run_spun "medindo cache HTTP do Chrome..." du -sk "$CHROME_CACHE" 2>/dev/null | awk '{print $1*1024}')
    printf '  %8s  %s\n' "$(human_bytes "${bs:-0}")" "cache HTTP/código (~/Library/Caches/Google/Chrome)"
    register_opp "${bs:-0}" "SEGURO" "$CHROME_CACHE" "Chrome: cache HTTP/código" \
      "rm -rf \"$CHROME_CACHE\"  # com o Chrome fechado; regenera navegando"
  fi

  if [[ -d "$CHROME_AS" ]]; then
    # Cache offline de PWAs (Service Workers), somado entre todos os perfis
    sw_kb=$(run_spun "medindo caches de PWAs do Chrome..." \
      du -sk "$CHROME_AS"/*/"Service Worker/CacheStorage" 2>/dev/null \
      | awk '{s+=$1} END {print s+0}')
    sw_bytes=$(( ${sw_kb:-0} * 1024 ))
    if [[ $sw_bytes -gt 0 ]]; then
      printf '  %8s  %s\n' "$(human_bytes "$sw_bytes")" "cache offline de PWAs (Service Worker, todos os perfis)"
      register_opp "$sw_bytes" "MODERADO" "$CHROME_AS" "Chrome: cache offline de PWAs" \
        "rm -rf \"$CHROME_AS\"/*/\"Service Worker/CacheStorage\"  # Chrome fechado; PWAs re-baixam"
    fi

    crx_kb=$(du -sk "$CHROME_AS/component_crx_cache" 2>/dev/null | awk '{print $1}')
    crx_bytes=$(( ${crx_kb:-0} * 1024 ))
    if [[ $crx_bytes -gt 0 ]]; then
      printf '  %8s  %s\n' "$(human_bytes "$crx_bytes")" "componentes baixados (component_crx_cache)"
      register_opp "$crx_bytes" "SEGURO" "$CHROME_AS/component_crx_cache" "Chrome: component_crx_cache" \
        "rm -rf \"$CHROME_AS/component_crx_cache\"  # Chrome fechado; re-baixa sozinho"
    fi
  fi

  out ""
  chrome_cap=$(defaults read com.google.Chrome DiskCacheSize 2>/dev/null || true)
  if [[ "$chrome_cap" =~ ^[0-9]+$ && "$chrome_cap" -gt 0 ]]; then
    out "  ${C_GREEN}✓ Cache HTTP limitado a $(human_bytes "$chrome_cap")${C_RESET} ${C_DIM}(política DiskCacheSize — o Chrome se auto-limpa)${C_RESET}"
  else
    out "  ${C_YELLOW}Dica:${C_RESET} limite o cache do Chrome de forma permanente (ele passa a se auto-limpar):"
    out "    ${C_BOLD}defaults write com.google.Chrome DiskCacheSize -int 2147483648${C_RESET}  ${C_DIM}# 2 GB; vale após reiniciar o Chrome${C_RESET}"
    register_tip 0 "Limitar o cache do Chrome a 2 GB (ele passa a se auto-limpar)" \
      "defaults write com.google.Chrome DiskCacheSize -int 2147483648  # vale após reiniciar o Chrome"
  fi
  if [[ $chrome_running -eq 1 ]]; then
    note "  ⚠ Chrome está aberto — os comandos rm acima exigem o Chrome fechado."
  fi
  note "  (Extensions, File System e IndexedDB são dados de sites/extensões, não cache — ficam de fora.)"
fi

}

# --- Homebrew -----------------------------------------------------------------

# Corpo de section_if: sem brew, não imprime nada
section_homebrew() {

if command -v brew >/dev/null 2>&1; then
  bc="$(brew --cache 2>/dev/null)"
  if [[ -n "$bc" && -d "$bc" ]]; then
    bc_kb=$(run_spun "medindo cache do Homebrew..." du -sk "$bc" 2>/dev/null | awk '{print $1}')
    out "  Cache: ${C_BOLD}$(human_bytes $(( ${bc_kb:-0} * 1024 )))${C_RESET}  ${C_DIM}($bc)${C_RESET}"
  fi
  # Fórmulas instaladas (no Linux ficam em /home/linuxbrew, fora do $HOME)
  bp="$(brew --prefix 2>/dev/null)"
  if [[ -n "$bp" && -d "$bp/Cellar" ]]; then
    cellar_kb=$(run_spun "medindo Cellar do Homebrew..." du -sk "$bp/Cellar" 2>/dev/null | awk '{print $1}')
    out "  Instalado: ${C_BOLD}$(human_bytes $(( ${cellar_kb:-0} * 1024 )))${C_RESET}  ${C_DIM}($bp/Cellar)${C_RESET}"
    brew_orphans=$(brew autoremove -n 2>/dev/null | grep -oE 'Would autoremove [0-9]+' | grep -oE '[0-9]+$')
    if [[ "${brew_orphans:-0}" -gt 0 ]]; then
      out "  ${C_YELLOW}${brew_orphans} dependência(s) órfã(s):${C_RESET} ${C_BOLD}brew autoremove${C_RESET}"
      register_tip 0 "Homebrew: ${brew_orphans} dependência(s) órfã(s) instalada(s)" \
        "brew autoremove  # remove o que nenhuma fórmula instalada usa"
    fi
  fi
  out ""

  # Dry-run usando as MESMAS flags do comando real (-s e --prune=all),
  # senão a estimativa fica enganosa (cleanup padrão só remove >120 dias).
  #
  # Conservador  → 'brew cleanup -n'              (só >120 dias)
  # Agressivo    → 'brew cleanup -ns --prune=all' (tudo, inclusive versão atual no cache)
  brew_default=$(run_spun "brew cleanup -n (padrão, >120 dias)..." brew cleanup -n 2>&1)
  brew_full=$(run_spun "brew cleanup -ns --prune=all (agressivo)..." brew cleanup -ns --prune=all 2>&1)

  brew_default_pot=$(printf '%s\n' "$brew_default" | grep -iE 'approximately|would free' | tail -1)
  brew_full_pot=$(printf '%s\n' "$brew_full"    | grep -iE 'approximately|would free' | tail -1)
  brew_full_count=$(printf '%s\n' "$brew_full"  | grep -c -E '^Would remove' || true)

  if [[ -z "$brew_default_pot" && -z "$brew_full_pot" ]]; then
    out "  ${C_GREEN}Nada a limpar${C_RESET} ${C_DIM}(nem o brew cleanup agressivo acha o que remover)${C_RESET}"
    return 0
  fi

  out "  ${C_DIM}Modo conservador (brew cleanup):${C_RESET}"
  if [[ -n "$brew_default_pot" ]]; then
    out "    ${brew_default_pot}"
  else
    out "    ${C_GREEN}Nada a limpar.${C_RESET}"
  fi
  out ""
  out "  ${C_BOLD}Modo agressivo (brew cleanup -s --prune=all):${C_RESET}"
  if [[ -n "$brew_full_pot" ]]; then
    out "    ${C_YELLOW}${brew_full_pot}${C_RESET}"
    if [[ ${brew_full_count:-0} -gt 0 ]]; then
      out "    ${C_DIM}(${brew_full_count} item(ns) seriam removidos)${C_RESET}"
    fi
    # Registra como oportunidade extraindo o tamanho ("approximately 7.3GB")
    brew_size_str=$(echo "$brew_full_pot" | grep -oE '[0-9.]+[[:space:]]*[KMGT]?B' | head -1 | tr -d ' ')
    if [[ -n "$brew_size_str" ]]; then
      brew_bytes=$(parse_size_to_bytes "$brew_size_str")
      # path = cache do brew: dedup com a mesma pasta vista na seção de caches
      register_opp "${brew_bytes:-0}" "SEGURO" "${bc:-}" "Homebrew (cleanup -s --prune=all)" "brew cleanup -s --prune=all"
    fi
  else
    out "    ${C_GREEN}Nada a limpar.${C_RESET}"
  fi

  out ""
  out "  ${C_GREEN}Para limpar de verdade (escolha um):${C_RESET}"
  out "    ${C_BOLD}brew cleanup${C_RESET}                      ${C_DIM}# conservador${C_RESET}"
  out "    ${C_BOLD}brew cleanup -s --prune=all${C_RESET}       ${C_DIM}# agressivo, libera bem mais${C_RESET}"
fi

}

# --- Docker / OrbStack / Colima / Podman --------------------------------------

# Corpo de section_if: sem nenhum runtime de container, não imprime nada
section_containers() {

# Detecta runtimes instalados (mesmo que não estejam rodando)
has_orbstack=0; has_docker_desktop=0; has_colima=0; has_podman=0
if [[ $OS == macos ]]; then
  [[ -d /Applications/OrbStack.app ]] && has_orbstack=1
  [[ -d /Applications/Docker.app ]] && has_docker_desktop=1
else
  [[ -d /opt/docker-desktop ]] && has_docker_desktop=1
  command -v podman >/dev/null 2>&1 && has_podman=1
fi
command -v colima >/dev/null 2>&1 && has_colima=1

docker_running=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker_running=1
fi

# No Linux o daemon pode estar rodando e o usuário não ter permissão no socket
docker_no_perm=0
if [[ $OS == linux && $docker_running -eq 0 ]] \
   && command -v docker >/dev/null 2>&1 && [[ -S /var/run/docker.sock ]]; then
  docker_no_perm=1
fi

if [[ $docker_running -eq 1 ]]; then
  out "  ${C_DIM}docker system df:${C_RESET}"
  docker system df 2>/dev/null | sed 's/^/    /'
  out ""
  # A coluna RECLAIMABLE da tabela é o que o prune liberaria
  docker_total_bytes=$(container_df_bytes docker Reclaimable)
  register_opp "${docker_total_bytes:-0}" "REVISAR" "" "Docker (imagens/containers/volumes reclaimable)" "docker system prune -a --volumes  # CUIDADO: apaga volumes não-anexados"
  out "  ${C_GREEN}Para limpar imagens, redes e build cache não usados:${C_RESET}"
  out "    ${C_BOLD}docker system prune -a --volumes${C_RESET}   ${C_RED}# cuidado: apaga volumes não-anexados${C_RESET}"
elif [[ $has_orbstack -eq 1 ]]; then
  out "  ${C_YELLOW}⚠ OrbStack instalado mas não está rodando.${C_RESET}"
  out "  ${C_DIM}Containers/imagens/volumes podem estar ocupando muito espaço.${C_RESET}"
  out ""
  out "  Para incluir essa análise:"
  out "    1. Inicie o OrbStack: ${C_BOLD}open -a OrbStack${C_RESET}"
  out "    2. Aguarde o ícone ficar pronto na barra de menu"
  out "    3. Rode ${C_BOLD}hogspot${C_RESET} de novo"
  register_blind "OrbStack parado: containers, imagens e volumes não foram medidos (open -a OrbStack e rode de novo)"
elif [[ $has_docker_desktop -eq 1 ]]; then
  out "  ${C_YELLOW}⚠ Docker Desktop instalado mas não está rodando.${C_RESET}"
  out "  Para incluir análise: ${C_BOLD}open -a Docker${C_RESET}, espere subir e rode hogspot de novo."
  register_blind "Docker Desktop parado: imagens e volumes não foram medidos (open -a Docker e rode de novo)"
elif [[ $has_colima -eq 1 ]]; then
  out "  ${C_YELLOW}⚠ Colima instalado mas não está rodando.${C_RESET}"
  out "  Para iniciar: ${C_BOLD}colima start${C_RESET}, depois rode hogspot de novo."
  register_blind "Colima parado: imagens e volumes não foram medidos (colima start e rode de novo)"
elif [[ $docker_no_perm -eq 1 ]]; then
  out "  ${C_YELLOW}⚠ O daemon do Docker responde, mas seu usuário não tem acesso ao socket.${C_RESET}"
  out "  Para incluir essa análise: ${C_BOLD}sudo usermod -aG docker \"$(id -un)\"${C_RESET} (relogue), ou rode com sudo."
  register_blind "Docker: seu usuário não acessa o socket, então o que o prune liberaria não foi medido"
elif [[ $OS == linux && -d /var/lib/docker ]]; then
  out "  ${C_YELLOW}⚠ Docker instalado mas o daemon não está rodando.${C_RESET}"
  out "  Para iniciar: ${C_BOLD}sudo systemctl start docker${C_RESET}, depois rode hogspot de novo."
  register_blind "Docker parado: o que o prune liberaria não foi medido (sudo systemctl start docker e rode de novo)"
fi

# /var/lib/docker é onde tudo mora no Linux — mede mesmo com o daemon parado.
# No Docker 29+ as imagens ficam no store do containerd (/var/lib/containerd).
# Com o daemon respondendo, o reclaimable acima já é a parte liberável e o
# tamanho em disco vira só informação (registrar os dois contaria duas vezes).
if [[ $OS == linux ]]; then
  docker_risk="REVISAR"; [[ $docker_running -eq 1 ]] && docker_risk="-"
  podman_risk="REVISAR"; [[ $has_podman -eq 1 ]] && podman_risk="-"
  sys_report_dir /var/lib/docker "$docker_risk" "Docker (/var/lib/docker: imagens, volumes, build cache)" \
    "docker system prune -a --volumes  # CUIDADO: apaga volumes não-anexados"
  sys_report_dir /var/lib/containerd "$docker_risk" "containerd (/var/lib/containerd: imagens do Docker 29+)" \
    "docker image prune -a  # com o daemon rodando"
  sys_report_dir /var/lib/containers "$podman_risk" "Podman (/var/lib/containers)" \
    "podman system prune -a --volumes"
fi

# Podman roda sem daemon: dá pra consultar direto
if [[ $has_podman -eq 1 ]]; then
  out ""
  out "  ${C_DIM}podman system df:${C_RESET}"
  podman system df 2>/dev/null | sed 's/^/    /'
  podman_bytes=$(container_df_bytes podman Reclaimable)
  register_opp "${podman_bytes:-0}" "REVISAR" "" "Podman (imagens/containers/volumes reclaimable)" \
    "podman system prune -a --volumes"
  out "  ${C_GREEN}Para limpar:${C_RESET} ${C_BOLD}podman system prune -a --volumes${C_RESET}"
fi

}

# =============================================================================
# RELATÓRIO
# =============================================================================

GENERATED_AT=$(date '+%Y-%m-%d %H:%M:%S')

print_header() {
  out "${C_BOLD}╭──────────────────────────────────────────────────────────╮${C_RESET}"
  out "${C_BOLD}│  hogspot — caçando os disk hogs                          │${C_RESET}"
  out "${C_BOLD}╰──────────────────────────────────────────────────────────╯${C_RESET}"
  out "${C_DIM}Gerado em $GENERATED_AT${C_RESET}"
  out "${C_DIM}Sistema: $(os_label)${C_RESET}"
}

# Varre tudo e imprime o relatório completo, seção por seção. Cada achado
# liberável vai pro $OPPS_FILE; o resumo do fim sai de lá.
full_report() {

if [[ $OS == macos ]] && ! has_full_disk_access; then
  out ""
  out "${C_YELLOW}⚠ Terminal sem Full Disk Access — áreas como Mail/Messages/Safari não serão"
  out "  contadas e o relatório pode subestimar. Habilite em: Ajustes do Sistema →"
  out "  Privacidade e Segurança → Acesso Total ao Disco → seu terminal.${C_RESET}"
  register_blind "Sem Full Disk Access: Mail, Messages e Safari ficaram de fora (Ajustes → Privacidade e Segurança → Acesso Total ao Disco)"
elif [[ $OS == linux && $EUID -ne 0 ]] && ! system_dirs_readable; then
  out ""
  out "${C_YELLOW}⚠ Sem root — áreas do sistema (/var/lib/docker, journal, /var/crash) não são"
  out "  legíveis e o relatório pode subestimar. Pra contar tudo (segue read-only):"
  out "    ${C_BOLD}sudo HOME=\"$HOME\" $0${C_RESET}${C_YELLOW}${C_RESET}"
fi

# --- Visão geral do disco ---
section "Visão geral do disco principal"
if [[ $OS == macos ]]; then
  disk_overview_macos
else
  disk_overview_linux
  root_map_linux
fi

# --- Snapshots locais ---
if [[ $OS == macos ]]; then
  section_if "Snapshots locais do Time Machine" snapshots_macos
else
  section_if "Snapshots locais (ZFS / Timeshift / Btrfs)" snapshots_linux
fi

# --- Pastas top-level da home ---
section "Top $TOP_N pastas em \$HOME"
run_spun "escaneando \$HOME..." top_children "$HOME" "$TOP_N"

# --- Downloads ---
dl_label=$(tilde "$DOWNLOADS_DIR")
section "Downloads — arquivos grandes (>100 MB)"
if [[ -d "$DOWNLOADS_DIR" ]]; then
  dl_bytes=$(run_spun "medindo $dl_label..." du -sk "$DOWNLOADS_DIR" 2>/dev/null | awk '{print $1*1024}')
  dl_total=$(human_bytes "${dl_bytes:-0}")
  out "  ${C_DIM}Total da pasta ($dl_label):${C_RESET} ${C_BOLD}${dl_total}${C_RESET}"
  out ""
  run_spun "procurando arquivos >100MB em $dl_label..." big_files "$DOWNLOADS_DIR" 100 3 "$TOP_N"
  if same_fs "$DOWNLOADS_DIR" "$HOME"; then
    register_opp "${dl_bytes:-0}" "REVISAR" "$DOWNLOADS_DIR" "$dl_label (revisar arquivos grandes)" \
      "# veja os maiores com: ls -lhS \"$DOWNLOADS_DIR\" | head"
  else
    dl_mount=$(df -P "$DOWNLOADS_DIR" 2>/dev/null | awk 'NR==2 {print $NF}')
    out ""
    note "  Fica em outro filesystem ($dl_mount) —"
    note "  apagar aqui não libera espaço no disco da home; fica fora do resumo."
    register_blind "$dl_label ($(human_bytes "${dl_bytes:-0}")) fica em outro disco ($dl_mount): limpar lá não libera espaço aqui"
  fi
fi

# --- Lixeira (só aparece com algo dentro) ---
status "Lixeira"
trash_total_bytes=0
trash_main=""
trash_lines=""
while IFS= read -r tb; do
  [[ -n "$tb" && -e "$tb" ]] || continue
  [[ -n "$trash_main" ]] || trash_main="$tb"
  b=$(du -sk "$tb" 2>/dev/null | awk '{print $1*1024}')
  [[ ${b:-0} -ge $((MIN_LIST_KB * 1024)) ]] || continue
  trash_total_bytes=$((trash_total_bytes + b))
  trash_lines+="$(printf '  %8s  %s' "$(human_bytes "$b")" "$tb")"$'\n'
done < <(trash_locations)
trash_cmd=$(empty_trash_cmd)
if [[ $trash_total_bytes -gt 0 ]]; then
  section "Lixeira (Trash)"
  printf '%s' "$trash_lines"
  note "Esvazie pelo gerenciador de arquivos ou: $trash_cmd"
fi
register_opp "$trash_total_bytes" "SEGURO" "${trash_main:-$HOME/.Trash}" "Lixeira (todos os volumes)" "$trash_cmd"

# --- Caches do usuário ---
cache_label=$(tilde "$CACHE_DIR")
section "$cache_label — top $TOP_N"
run_spun "escaneando $cache_label..." top_children_register "$CACHE_DIR" "$TOP_N" "SEGURO" "Cache" 'rm -rf "{}"'
out ""
note "Geralmente é seguro apagar em $cache_label — apps regeneram."
note "Exceções vêm marcadas com o risco ao lado (repositórios git clonados$([[ $OS == macos ]] && printf ', iCloud/sistema'))."
note "Itens com comando próprio de limpeza (pip, uv, go, Homebrew...) aparecem com ele no resumo."

# --- Dados de apps (Application Support / ~/.local/share) ---
appdata_label=$(tilde "$APPDATA_DIR")
if [[ $OS == macos ]]; then
  appdata_tag="Application Support"
  appdata_cmd='# revisar pelo app: {}'
else
  appdata_tag="Dados de app"
  appdata_cmd='# dados do app (não é cache) — revise antes: {}'
fi
section "$appdata_label — top $TOP_N"
run_spun "escaneando $appdata_label... (pode demorar)" top_children_register "$APPDATA_DIR" "$TOP_N" "REVISAR" "$appdata_tag" "$appdata_cmd"

# --- Sandboxes / apps empacotados ---
if [[ $OS == macos ]]; then
  containers_macos
else
  containers_linux
fi

# --- Logs (no Linux ficam na seção "Sistema", junto do journal) ---
if [[ $OS == macos ]]; then
  section "~/Library/Logs — top 10"
  run_spun "escaneando ~/Library/Logs..." top_children "$HOME/Library/Logs" 10
fi

# --- Xcode / iOS (macOS) ---
if [[ $OS == macos ]]; then
  section_if "~/Library/Developer (Xcode, simuladores)" section_dev_xcode
  section_if "Backups de iPhone/iPad (MobileSync)" section_mobilesync
fi

# --- Sistema: pacotes, logs e crashes (Linux) ---
if [[ $OS == linux ]]; then
  section_linux_system
fi

# --- Caches espalhadas de dev ---
section "Caches de ferramentas de dev (raiz do \$HOME)"
# formato: dir|risco|comando
declare -a dev_dirs=(
  '.npm|SEGURO|npm cache clean --force'
  '.pnpm-store|SEGURO|pnpm store prune'
  '.yarn/cache|SEGURO|yarn cache clean'
  '.cargo|REVISAR|# contém binários instalados em ~/.cargo/bin; não apague inteiro'
  '.gradle|MODERADO|rm -rf "$HOME/.gradle/caches"  # rebuild baixa de novo'
  '.m2/repository|MODERADO|rm -rf "$HOME/.m2/repository"  # deps baixam de novo no build'
  '.ivy2|MODERADO|# deps ivy/sbt; baixam de novo no próximo build'
  '.sbt|MODERADO|# caches do sbt; regeneram no próximo build'
  '.pyenv|REVISAR|# versões de Python instaladas; apagar quebra virtualenvs'
  '.rbenv|REVISAR|# versões de Ruby instaladas'
  '.nvm|MODERADO|# no seu shell (nvm é função, não binário): nvm cache clear; nvm uninstall <versão antiga>'
  '.rustup|MODERADO|rustup toolchain uninstall <antiga>  # liste com: rustup toolchain list'
  '.bun/install/cache|SEGURO|bun pm cache rm'
  'go/pkg/mod|MODERADO|go clean -modcache'
  '.minikube|MODERADO|minikube delete --all'
  '.vagrant.d|MODERADO|vagrant box prune'
  '.docker|REVISAR|# config/estado do Docker; use docker system prune em vez de apagar'
)
if [[ $OS == macos ]]; then
  dev_dirs+=(
    '.cache|MODERADO|# pode conter modelos/downloads grandes (huggingface, uv, etc); revise antes'
    '.cocoapods|MODERADO|pod cache clean --all'
    'Library/pnpm|MODERADO|pnpm store prune'
    '.colima|REVISAR|# disco da VM Colima (contém suas imagens e volumes)'
    '.lima|REVISAR|# discos de VMs Lima'
    '.orbstack|REVISAR|# dados do OrbStack; limpe com docker prune com ele rodando'
  )
else
  # No Linux o ~/.cache já é a seção de caches do usuário — não repete aqui.
  dev_dirs+=(
    '.local/share/pnpm|MODERADO|pnpm store prune'
    '.local/share/virtualenvs|REVISAR|# virtualenvs do pipenv; recriáveis com pipenv install'
    '.local/share/containers|REVISAR|# imagens/volumes do Podman: podman system prune -a'
    '.local/lib|REVISAR|# pacotes Python instalados com pip --user'
    '.nv|SEGURO|rm -rf "$HOME/.nv/ComputeCache"  # cache de kernels CUDA; regenera'
    '.conda|MODERADO|conda clean --all'
  )
fi
for entry in "${dev_dirs[@]}"; do
  IFS='|' read -r d dev_risk dev_cmd <<< "$entry"
  p="$HOME/$d"
  [[ -e "$p" ]] || continue
  b=$(du -sk "$p" 2>/dev/null | awk '{print $1*1024}')
  [[ ${b:-0} -ge $((MIN_LIST_KB * 1024)) ]] || continue
  printf "  %8s  ~/%s\n" "$(human_bytes "$b")" "$d"
  if [[ $DETAIL -eq 1 ]] && detail_dev_cache "$d" "$p"; then
    continue  # breakdown já registrou oportunidades mais específicas
  fi
  register_opp "${b:-0}" "$dev_risk" "$p" "Dev cache: ~/$d" "$dev_cmd"
done

# Claude Code: o instalador nativo guarda cada versão inteira (~300 MB) em
# versions/, e os transcripts das sessões só somem após cleanupPeriodDays
cc_versions="${XDG_DATA_HOME:-$HOME/.local/share}/claude/versions"
if [[ -d "$cc_versions" ]]; then
  cc_current=$(basename "$(readlink -f "$HOME/.local/bin/claude" 2>/dev/null)")
  # sem o link do instalador, a versão em uso é a mais recente
  if [[ -z "$cc_current" || ! -f "$cc_versions/$cc_current" ]]; then
    # shellcheck disable=SC2012  # nomes de versão (2.1.310) não têm espaço
    cc_current=$(ls -t "$cc_versions" 2>/dev/null | head -1)
  fi
  # Sem saber qual está em uso, não sugere nada (o ! -name vazio pegaria todas)
  cc_old_n=0
  [[ -n "$cc_current" ]] && \
    read -r cc_old_kb cc_old_n <<< "$(find "$cc_versions" -mindepth 1 -maxdepth 1 -type f ! -name "$cc_current" \
        -exec du -k {} + 2>/dev/null | awk '{ s += $1; n++ } END { print s+0, n+0 }')"
  if [[ ${cc_old_n:-0} -gt 0 ]]; then
    printf "  %8s  %s\n" "$(human_bytes $((cc_old_kb * 1024)))" \
      "$(tilde "$cc_versions") (${cc_old_n} versão(ões) antiga(s) do Claude Code; em uso: $cc_current)"
    cc_cmd="find \"$cc_versions\" -maxdepth 1 -type f ! -name \"$cc_current\" -delete  # mantém a $cc_current, em uso"
    shell_safe "$cc_current" || cc_cmd="# apague as versões antigas à mão: $cc_cmd"
    register_opp $((cc_old_kb * 1024)) "SEGURO" "$cc_versions" "Claude Code: ${cc_old_n} versão(ões) antiga(s)" "$cc_cmd"
  fi
fi
cc_projects="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
if [[ -d "$cc_projects" ]]; then
  cc_kb=$(du -sk "$cc_projects" 2>/dev/null | awk '{print $1}')
  if [[ ${cc_kb:-0} -gt 0 ]]; then
    printf "  %8s  %s\n" "$(human_bytes $((cc_kb * 1024)))" "$(tilde "$cc_projects") (transcripts do Claude Code)"
    register_opp $((cc_kb * 1024)) "REVISAR" "$cc_projects" "Claude Code: transcripts das sessões" \
      "# baixe \"cleanupPeriodDays\" em ~/.claude/settings.json (padrão: 30 dias); sessões mais velhas saem do /resume"
  fi
fi

if [[ $DETAIL -eq 0 ]]; then
  out ""
  note "Rode com --detail pra ver a composição interna e comandos por subpasta."
fi

# --- Homebrew ---
section_if "Homebrew" section_homebrew

# --- Docker / OrbStack / Colima ---
section_if "Docker / containers" section_containers

# --- Navegadores ---
if [[ $OS == macos ]]; then
  section_browsers_macos
else
  section_browsers_linux
fi

# --- Projetos: node_modules, artefatos de build e worktrees ---
if [[ $QUICK -eq 0 ]]; then
  section "Projetos em \$HOME — node_modules, builds e worktrees"
  run_spun "varrendo projetos em \$HOME (pode demorar 30s-2min)..." scan_projects
else
  register_blind "--quick: node_modules, builds, worktrees e arquivos >1 GB pelo \$HOME não foram varridos"
fi

# --- Arquivos isolados gigantes em ~ ---
if [[ $QUICK -eq 0 ]]; then
  section "Arquivos isolados gigantes em \$HOME (>1 GB, profundidade ≤5)"
  run_spun "procurando arquivos >1GB em \$HOME (pode demorar)..." big_files_register "$HOME" 1024 5 "$TOP_N" "REVISAR" "Arquivo grande"
fi


}  # fim de full_report

# =============================================================================
# RESUMO
# =============================================================================

# Itens do resumo na ordem em que aparecem (o número no menu é o índice + 1).
# Agrupados por risco — SEGURO, MODERADO, REVISAR, AJUSTE — e por tamanho.
IT_BYTES=() IT_RISK=() IT_PATH=() IT_DESC=() IT_CMD=() IT_DONE=()
SUM_SEGURO=0 SUM_MODERADO=0 SUM_REVISAR=0
SMALL_STATS=""   # "risco<TAB>contagem<TAB>bytes" dos itens abaixo de MIN_SUMMARY_BYTES

build_items() {
  local kept g bytes risk path desc cmd
  [[ -s "$OPPS_FILE" ]] || return 0

  # Dedup por contenção de path: um item dentro de outro item registrado é
  # descartado (o ancestral já conta esses bytes). Exceção: se o descendente
  # cobre >=90% do ancestral, ele substitui — é o mesmo espaço com conselho
  # mais específico (ex.: MobileSync/Backup dentro de Application Support).
  kept=$(LC_ALL=C sort -t$'\t' -k3,3 -k5,5 "$OPPS_FILE" | awk -F'\t' '
    function flush() { if (root_line != "") print root_line }
    BEGIN { root_path = ""; root_line = "" }
    {
      bytes = $1 + 0; path = $3
      if (path == "") { print; next }   # sem path: passa direto
      if (root_path != "" && (path == root_path || index(path, root_path "/") == 1)) {
        if (root_bytes > 0 && bytes >= 0.9 * root_bytes) root_line = $0
        next
      }
      flush()
      root_path = path; root_bytes = bytes; root_line = $0
    }
    END { flush() }
  ')

  read -r SUM_SEGURO SUM_MODERADO SUM_REVISAR <<< "$(awk -F'\t' '
    { s[$2] += $1 }
    END { printf "%d %d %d\n", s["SEGURO"]+0, s["MODERADO"]+0, s["REVISAR"]+0 }
  ' <<< "$kept")"

  # Maior primeiro, uma linha por descrição (caso o mesmo item entre duas
  # vezes); os pequenos viram estatística, o resto vira item. Separador \037:
  # o read colapsaria tabs seguidos, e o path pode vir vazio.
  kept=$(sort -t$'\t' -k1,1nr <<< "$kept" | awk -F'\t' '!seen[$4]++')
  SMALL_STATS=$(awk -F'\t' -v min="$MIN_SUMMARY_BYTES" '
    $2 != "AJUSTE" && $1 < min { n[$2]++; b[$2] += $1 }
    END { for (r in n) printf "%s\t%d\t%d\n", r, n[r], b[r] }
  ' <<< "$kept")
  while IFS=$'\037' read -r g bytes risk path desc cmd; do
    [[ -n "$risk" ]] || continue
    IT_BYTES+=("$bytes"); IT_RISK+=("$risk"); IT_PATH+=("$path")
    IT_DESC+=("$desc"); IT_CMD+=("$cmd"); IT_DONE+=(0)
  done < <(awk -F'\t' -v OFS=$'\037' -v min="$MIN_SUMMARY_BYTES" '
      $2 != "AJUSTE" && $1 < min { next }
      { g = ($2 == "SEGURO") ? 1 : ($2 == "MODERADO") ? 2 : ($2 == "REVISAR") ? 3 : 4
        print g, $1, $2, $3, $4, $5 }
    ' <<< "$kept" | sort -s -t$'\037' -k1,1n)
}

risk_color() {
  case "$1" in
    SEGURO)   printf '%s' "$C_GREEN" ;;
    MODERADO) printf '%s' "$C_YELLOW" ;;
    REVISAR)  printf '%s' "$C_RED" ;;
    *)        printf '%s' "$C_CYAN" ;;
  esac
}

risk_meaning() {
  case "$1" in
    SEGURO)   echo "regenera sozinho" ;;
    MODERADO) echo "custa re-download ou rebuild" ;;
    REVISAR)  echo "decisão sua: pode haver dado seu" ;;
    *)        echo "ajustes e extras; não entram nos totais acima" ;;
  esac
}

risk_title() {
  case "$1" in
    AJUSTE) echo "OUTRAS AÇÕES" ;;
    *)      echo "$1" ;;
  esac
}

# Disco onde os itens liberam espaço (no macOS, o volume Data do container APFS)
main_fs_path() {
  if [[ $OS == macos && -d /System/Volumes/Data ]]; then
    echo /System/Volumes/Data
  else
    echo /
  fi
}

# fs_stats <path> → "tamanho_kb em_uso_kb livre_kb" (APFS: em uso = tamanho - livre)
fs_stats() {
  df -Pk "$1" 2>/dev/null | awk -v mac="$([[ $OS == macos ]] && echo 1)" '
    NR == 2 { print $2, (mac ? $2 - $4 : $3), $4 }'
}

avail_kb() {
  df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# $HOME num disco separado do principal (/home dedicado): cada item libera
# espaço no seu disco, e não dá pra somar tudo num "livre depois"
home_on_other_disk() {
  [[ $OS == linux ]] && ! same_fs "$HOME" /
}

# free_delta <rótulo> <livre_kb de antes> <path> — quanto o disco ganhou
free_delta() {
  local after delta
  after=$(avail_kb "$3")
  delta=$(( (${after:-0} - ${2:-0}) * 1024 ))
  if [[ $delta -gt 0 ]]; then
    printf '  %sLivre agora (%s): %s (+%s)%s\n' "$C_BOLD" "$1" \
      "$(human_bytes $(( ${after:-0} * 1024 )))" "$(human_bytes "$delta")" "$C_RESET"
  else
    printf '  Livre agora (%s): %s %s(sem mudança)%s\n' "$1" \
      "$(human_bytes $(( ${after:-0} * 1024 )))" "$C_DIM" "$C_RESET"
  fi
}

# disk_line <path> <rótulo>
disk_line() {
  local size used avail pct denom
  read -r size used avail <<< "$(fs_stats "$1")"
  [[ "${size:-0}" -gt 0 ]] || return 0
  denom=$(( used + avail > 0 ? used + avail : 1 ))
  pct=$(( (used * 100 + denom - 1) / denom ))
  printf '  %s%s: %s de %s em uso (%d%%) — %s livres%s\n' "$C_BOLD" "$2" \
    "$(human_bytes $((used * 1024)))" "$(human_bytes $((size * 1024)))" "$pct" \
    "$(human_bytes $((avail * 1024)))" "$C_RESET"
}

# Parte executável de um comando sugerido (sem o comentário do fim)
CMD_SEP='  # '
cmd_code() {
  [[ "${1:0:1}" == "#" ]] && return 0
  printf '%s\n' "${1%%"$CMD_SEP"*}"
}

# Comentário do fim do comando — ou o comando inteiro, quando é só instrução
cmd_note() {
  local c="$1"
  if [[ "${c:0:1}" == "#" ]]; then
    c="${c#\#}"
    printf '%s\n' "${c# }"
  elif [[ "$c" == *"$CMD_SEP"* ]]; then
    printf '%s\n' "${c#*"$CMD_SEP"}"
  fi
}

# O menu pode rodar este item? Não quando o comando é só instrução, tem
# lacuna pra preencher (<projeto>, <id>) ou o path tem caractere que viraria
# código dentro das aspas.
item_runnable() {
  local code re='<[^<> ]+>'
  code=$(cmd_code "${IT_CMD[$1]}")
  [[ -n "$code" ]] || return 1
  [[ "$code" =~ $re ]] && return 1
  # shellcheck disable=SC2016  # $( e crase literais: substituição de comando
  [[ "$code" == *'$('* || "$code" == *'`'* ]] && return 1
  [[ -z "${IT_PATH[$1]}" ]] || shell_safe "${IT_PATH[$1]}"
}

# Lista numerada, por grupo de risco. $1 = 1 mostra o comando de cada item
# (sem menu, é a única forma de chegar nele).
print_items() {
  local show_cmds="$1" risk i n=${#IT_DESC[@]} any small_n small_b total
  for risk in SEGURO MODERADO REVISAR AJUSTE; do
    any=0
    for ((i = 0; i < n; i++)); do [[ "${IT_RISK[$i]}" == "$risk" ]] && any=1 && break; done
    small_n=0 small_b=0
    read -r small_n small_b <<< "$(awk -F'\t' -v r="$risk" '$1 == r { print $2, $3 }' <<< "$SMALL_STATS")"
    [[ $any -eq 1 || ${small_n:-0} -gt 0 ]] || continue

    total=""
    case "$risk" in
      SEGURO)   total=$SUM_SEGURO ;;
      MODERADO) total=$SUM_MODERADO ;;
      REVISAR)  total=$SUM_REVISAR ;;
    esac
    out ""
    printf '  %s%s%s%s %s— %s%s' "$C_BOLD" "$(risk_color "$risk")" "$(risk_title "$risk")" "$C_RESET" \
      "$C_DIM" "$(risk_meaning "$risk")" "$C_RESET"
    [[ -n "$total" ]] && printf ' %s(%s no total)%s' "$C_DIM" "$(human_bytes "$total")" "$C_RESET"
    printf '\n'

    for ((i = 0; i < n; i++)); do
      [[ "${IT_RISK[$i]}" == "$risk" ]] || continue
      local size=""
      [[ ${IT_BYTES[$i]} -gt 0 ]] && size=$(human_bytes "${IT_BYTES[$i]}")
      printf '   %s%3d.%s %9s  %s' "$C_BOLD" $((i + 1)) "$C_RESET" "$size" "${IT_DESC[$i]}"
      if [[ ${IT_DONE[$i]} -eq 1 ]]; then
        printf '  %s✓ feito%s' "$C_GREEN" "$C_RESET"
      elif [[ $show_cmds -eq 0 ]] && ! item_runnable "$i"; then
        printf '  %s(manual)%s' "$C_DIM" "$C_RESET"
      fi
      printf '\n'
      [[ $show_cmds -eq 1 ]] && printf '                 %s↳ %s%s\n' "$C_DIM" "${IT_CMD[$i]}" "$C_RESET"
    done
    [[ ${small_n:-0} -gt 0 ]] && printf '                 %s+%d item(ns) menor(es) que %s (%s)%s\n' \
      "$C_DIM" "$small_n" "$(human_bytes "$MIN_SUMMARY_BYTES")" "$(human_bytes "$small_b")" "$C_RESET"
  done
  return 0
}

print_summary() {
  local show_cmds="$1" main same_fs=1 line
  main=$(main_fs_path)

  section "Resumo"
  if [[ $OS == macos ]]; then
    disk_line "$main" "Disco (container APFS)"
  else
    disk_line / "Disco (/)"
    if home_on_other_disk; then
      disk_line "$HOME" "\$HOME ($(df -P "$HOME" 2>/dev/null | awk 'NR==2 {print $NF}'))"
      same_fs=0
    fi
  fi
  out ""

  if [[ $((SUM_SEGURO + SUM_MODERADO + SUM_REVISAR)) -eq 0 ]]; then
    out "  ${C_GREEN}Nada relevante pra limpar.${C_RESET}"
  else
    local acc risk sum label
    acc=$(avail_kb "$main")
    acc=$(( ${acc:-0} * 1024 ))
    if [[ $same_fs -eq 1 ]]; then
      printf '  Dá pra liberar  %10s %14s\n' "libera" "livre depois"   # 'á' tem 2 bytes: sem %-16s
    else
      printf '  %s\n' "Dá pra liberar"
    fi
    for risk in SEGURO MODERADO REVISAR; do
      case "$risk" in
        SEGURO)   sum=$SUM_SEGURO;   label="  SEGURO" ;;
        MODERADO) sum=$SUM_MODERADO; label="+ MODERADO" ;;
        REVISAR)  sum=$SUM_REVISAR;  label="+ REVISAR" ;;
      esac
      acc=$((acc + sum))
      printf '  %s%-16s%s %10s' "$(risk_color "$risk")" "$label" "$C_RESET" \
        "$( [[ $sum -gt 0 ]] && human_bytes "$sum" || echo "-")"
      [[ $same_fs -eq 1 ]] && printf ' %14s' "$(human_bytes "$acc")"
      printf '   %s%s%s\n' "$C_DIM" "$(risk_meaning "$risk")" "$C_RESET"
    done
    note "  (estimativas: itens sobrepostos contam uma vez)"
  fi

  if [[ ${#IT_DESC[@]} -gt 0 ]]; then
    section "O que dá pra limpar"
    print_items "$show_cmds" | sed '1{/^$/d;}'
  fi

  if [[ -s "$BLIND_FILE" ]]; then
    out ""
    out "  ${C_YELLOW}Fora da conta:${C_RESET}"
    while IFS= read -r line; do
      printf '    · %s\n' "$line"
    done < <(awk '!seen[$0]++' "$BLIND_FILE")
  fi
  return 0
}

# Relatório completo + resumo, sem cores, num arquivo markdown
write_report() {
  {
    echo "# Relatório hogspot — $GENERATED_AT"
    echo ""
    echo '```'
    { print_header; cat "$FULL_OUT"; print_summary 1; } | sed -E $'s/\x1b\\[[0-9;]*m//g'
    echo '```'
  } > "$1"
}

# =============================================================================
# MENU
# =============================================================================

# "1 3 5-7" ou "1,3" → índices (base 0), um por linha; falha se algo não valer
parse_selection() {
  local tok a b k n=${#IT_DESC[@]}
  for tok in $(printf '%s' "$1" | tr ',' ' '); do
    if [[ "$tok" =~ ^[0-9]+$ ]]; then
      a=$((10#$tok)); b=$a
    elif [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
    else
      return 1
    fi
    [[ $a -ge 1 && $a -le $b && $b -le $n ]] || return 1
    for ((k = a; k <= b; k++)); do echo $((k - 1)); done
  done
}

# confirm <pergunta> [palavra] — sem palavra aceita s/sim; com ela, só ela
confirm() {
  local ans
  if [[ -n "${2:-}" ]]; then
    printf '  %s Digite %s%s%s pra confirmar: ' "$1" "$C_BOLD" "$2" "$C_RESET"
    read -r ans || return 1
    [[ "$ans" == "$2" ]]
  else
    printf '  %s [s/N] ' "$1"
    read -r ans || return 1
    case "$ans" in s|S|sim|Sim|SIM|y|Y) return 0 ;; esac
    return 1
  fi
}

# Maiores itens dentro de um diretório (pro detalhe de um item)
inner_top() {
  du -sk "$1"/* "$1"/.[!.]* 2>/dev/null | sort -rn | head -5
}

# show_item <índice> <1 = olhar dentro da pasta>
show_item() {
  local i="$1" code note path="${IT_PATH[$1]}" size="" kb p
  [[ ${IT_BYTES[$i]} -gt 0 ]] && size=$(human_bytes "${IT_BYTES[$i]}")
  code=$(cmd_code "${IT_CMD[$i]}")
  note=$(cmd_note "${IT_CMD[$i]}")
  out ""
  printf '  %s%d. %s%s  %s%s%s%s  %s\n' "$C_BOLD" $((i + 1)) "${IT_DESC[$i]}" "$C_RESET" \
    "$C_BOLD" "$(risk_color "${IT_RISK[$i]}")" "$(risk_title "${IT_RISK[$i]}")" "$C_RESET" "$size"
  printf '     %s%s%s\n' "$C_DIM" "$(risk_meaning "${IT_RISK[$i]}")" "$C_RESET"
  [[ -n "$path" ]] && printf '     onde:     %s\n' "$(tilde "$path")"
  if item_runnable "$i"; then
    printf '     comando:  %s%s%s\n' "$C_BOLD" "$code" "$C_RESET"
    [[ -n "$note" ]] && printf '     nota:     %s\n' "$note"
  else
    [[ -n "$code" ]] && printf '     comando:  %s\n' "$code"
    [[ -n "$note" ]] && printf '     como:     %s\n' "$note"
    printf '     %s(manual: o hogspot não roda este — siga a instrução acima)%s\n' "$C_DIM" "$C_RESET"
  fi
  if [[ "$2" == 1 && -n "$path" && "$path" != *'*'* && -d "$path" && -r "$path" ]]; then
    local inner
    inner=$(run_spun "olhando dentro de $(tilde "$path")..." inner_top "$path")
    if [[ -n "$inner" ]]; then
      printf '     maiores dentro:\n'
      while IFS=$'\t' read -r kb p; do
        [[ -n "$kb" ]] && printf '     %9s  %s%s%s\n' "$(human_bytes $((kb * 1024)))" "$C_DIM" "$(basename "$p")" "$C_RESET"
      done <<< "$inner"
    fi
  fi
  return 0
}

# Roda os itens (índices) já confirmados e mostra quanto o disco ganhou
run_items() {
  local i code rc main before before_home=0 label="disco"
  main=$(main_fs_path)
  [[ $OS == linux ]] && label="/"
  before=$(avail_kb "$main")
  home_on_other_disk && before_home=$(avail_kb "$HOME")
  for i in "$@"; do
    code=$(cmd_code "${IT_CMD[$i]}")
    out ""
    printf '  %s$ %s%s\n' "$C_BOLD" "$code" "$C_RESET"
    # Rodando como root via sudo, o que não pede sudo roda como o dono da
    # home — senão pip/npm/brew limpariam (ou criariam) coisas do root
    if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "$code" != sudo\ * ]]; then
      sudo -u "$SUDO_USER" env HOME="$HOME" PATH="$PATH" bash -c "$code"
    else
      bash -c "$code"
    fi
    rc=$?
    if [[ $rc -eq 0 ]]; then
      IT_DONE[i]=1
      printf '  %s✓ %s%s\n' "$C_GREEN" "${IT_DESC[$i]}" "$C_RESET"
    else
      printf '  %s✗ %s — saiu com código %d%s\n' "$C_RED" "${IT_DESC[$i]}" "$rc" "$C_RESET"
    fi
  done
  out ""
  free_delta "$label" "$before" "$main"
  home_on_other_disk && free_delta "\$HOME" "$before_home" "$HOME"
  return 0
}

# Detalha os itens escolhidos e oferece rodar os que têm comando
select_items() {
  local sel i count run=() bytes=0 revisar=0 prompt
  if ! sel=$(parse_selection "$1") || [[ -z "$sel" ]]; then
    printf '  %sNão entendi "%s". Use números da lista (1 a %d), como 2 ou 1 3 5-7.%s\n' \
      "$C_YELLOW" "$1" "${#IT_DESC[@]}" "$C_RESET"
    return 0
  fi
  count=$(printf '%s\n' "$sel" | grep -c .)
  for i in $sel; do
    show_item "$i" "$([[ $count -le 3 ]] && echo 1 || echo 0)"
    [[ ${IT_DONE[$i]} -eq 1 ]] && { note "     (já rodado nesta sessão)"; continue; }
    item_runnable "$i" || continue
    run+=("$i")
    bytes=$((bytes + IT_BYTES[i]))
    [[ "${IT_RISK[$i]}" == REVISAR ]] && revisar=1
  done
  out ""
  if [[ ${#run[@]} -eq 0 ]]; then
    note "  Nada aqui pro hogspot rodar."
    return 0
  fi
  prompt="Rodar ${#run[@]} comando(s)"
  [[ $bytes -gt 0 ]] && prompt+=" (libera ~$(human_bytes "$bytes"))"
  if [[ $revisar -eq 1 ]]; then
    confirm "${C_RED}${prompt}? Inclui item REVISAR: o que ele apaga não volta.${C_RESET}" "sim" || { note "  Nada foi rodado."; return 0; }
  else
    confirm "${prompt}?" || { note "  Nada foi rodado."; return 0; }
  fi
  run_items "${run[@]}"
}

# Todos os SEGURO que o hogspot sabe rodar, numa confirmação só
run_all_safe() {
  local i n=${#IT_DESC[@]} run=() bytes=0
  out ""
  for ((i = 0; i < n; i++)); do
    [[ "${IT_RISK[$i]}" == SEGURO && ${IT_DONE[$i]} -eq 0 ]] || continue
    item_runnable "$i" || continue
    run+=("$i")
    bytes=$((bytes + IT_BYTES[i]))
    printf '   %s%3d.%s %9s  %s\n' "$C_BOLD" $((i + 1)) "$C_RESET" "$(human_bytes "${IT_BYTES[$i]}")" "${IT_DESC[$i]}"
    printf '                 %s$ %s%s\n' "$C_DIM" "$(cmd_code "${IT_CMD[$i]}")" "$C_RESET"
  done
  if [[ ${#run[@]} -eq 0 ]]; then
    note "  Nenhum item SEGURO pendente que o hogspot saiba rodar."
    return 0
  fi
  out ""
  confirm "Rodar estes ${#run[@]} comando(s) (libera ~$(human_bytes "$bytes"))?" || { note "  Nada foi rodado."; return 0; }
  run_items "${run[@]}"
}

view_full_report() {
  if command -v less >/dev/null 2>&1; then
    { print_header; cat "$FULL_OUT"; } | less -R
  else
    print_header; cat "$FULL_OUT"
  fi
}

save_report_prompt() {
  local def f
  def="$DOWNLOADS_DIR/hogspot-$(date +%F).md"
  printf '  Salvar em [%s]: ' "$(tilde "$def")"
  read -r f || return 0
  f="${f:-$def}"
  [[ "$f" == \~/* ]] && f="$HOME/${f#\~/}"
  if write_report "$f" 2>/dev/null; then
    printf '  %s✓ Relatório salvo em %s%s\n' "$C_GREEN" "$f" "$C_RESET"
  else
    printf '  %s✗ Não deu pra escrever em %s%s\n' "$C_RED" "$f" "$C_RESET"
  fi
}

menu() {
  local line
  [[ ${#IT_DESC[@]} -gt 0 ]] || return 0
  out ""
  out "  Digite números da lista (ex.: ${C_BOLD}2${C_RESET} ou ${C_BOLD}1 3 5-7${C_RESET}) pra ver detalhes e limpar."
  out "  ${C_BOLD}t${C_RESET} roda todos os SEGURO · ${C_BOLD}l${C_RESET} mostra a lista · ${C_BOLD}r${C_RESET} relatório completo · ${C_BOLD}s${C_RESET} salva em arquivo · ${C_BOLD}Enter${C_RESET} sai"
  out "  ${C_DIM}Nada roda sem você confirmar.${C_RESET}"
  while :; do
    printf '\n  %s›%s ' "$C_CYAN" "$C_RESET"
    read -r line || { out ""; return 0; }
    line=$(printf '%s' "$line" | awk '{$1 = $1; print}')   # apara espaços
    case "$line" in
      ""|q|Q|sair) return 0 ;;
      t|T) run_all_safe ;;
      l|L) print_items 0 ;;
      r|R) view_full_report ;;
      s|S) save_report_prompt ;;
      *) select_items "$line" ;;
    esac
  done
}

# =============================================================================
# EXECUÇÃO
# =============================================================================

print_header
if [[ $FULL -eq 1 ]]; then
  full_report | tee "$FULL_OUT"
else
  # Sem linha de status (sem cor ou sem TTY), avisa que a demora é normal
  [[ $SHOW_STATUS -eq 0 && -t 2 ]] && printf '  analisando... (pode levar alguns minutos)\n' >&2
  full_report > "$FULL_OUT"
fi
[[ $SHOW_STATUS -eq 1 ]] && printf '\r\033[K' >&2
SHOW_STATUS=0 STATUS_MSG=""

build_items
print_summary $((1 - MENU))
out ""
out "${C_GREEN}✓ Análise concluída em ${SECONDS} s.${C_RESET}"

if [[ -n "$REPORT_FILE" ]]; then
  if write_report "$REPORT_FILE"; then
    out "${C_GREEN}Relatório completo salvo em: $REPORT_FILE${C_RESET}"
  else
    printf 'Não deu pra escrever o relatório em %s\n' "$REPORT_FILE" >&2
  fi
fi

if [[ $MENU -eq 1 ]]; then
  menu
elif [[ $FULL -eq 0 && -z "$REPORT_FILE" ]]; then
  note "Dica: --full mostra o relatório seção por seção; --report ARQUIVO salva tudo."
fi
