#!/usr/bin/env bash
# =============================================================================
#  hogspot — finds where the disk hogs are hiding on your machine
#  The scan is read-only. Every opportunity is labeled by risk
#  (SAFE / MODERATE / REVIEW) with the command that frees the space; in a
#  terminal, a menu lets you run those commands — only after you confirm.
#
#  Usage:
#    hogspot                  # summary of what can be cleaned + menu
#    hogspot --full           # full report, section by section, before the summary
#    hogspot --top 20         # items per section in the full report (default: 15)
#    hogspot --report FILE    # saves the full report to a file (markdown)
#    hogspot --quick          # skips slow scans (projects and huge files)
#    hogspot --detail         # breaks down what is inside the dev caches
#    hogspot --no-menu        # print only, no questions at the end
#    hogspot --no-color       # no colors
#    hogspot --help           # help
#
#  Supports: macOS and Linux (Ubuntu/Debian first).
#  Uses only standard tools: du, find, df + tmutil/sw_vers on macOS and
#  dpkg/snap/flatpak/journalctl on Linux (each one only when present).
#
#  License: MIT (see LICENSE) — https://github.com/trentas/hogspot
# =============================================================================

set -uo pipefail

# ----- Configuration -----
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
      # prints the comment block at the top (between the two '=' rulers)
      awk '/^# ={10,}/ { n++; next } n == 1 { sub(/^# ?/, ""); print } n > 1 { exit }' "$0"
      exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1 ;;
  esac
done

if ! [[ "$TOP_N" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid value for --top: $TOP_N (expected a number > 0)" >&2
  exit 1
fi

# ----- Platform -----
case "$(uname -s)" in
  Darwin) OS=macos ;;
  Linux)  OS=linux ;;
  *)
    echo "hogspot supports macOS and Linux (detected: $(uname -s))" >&2
    exit 1 ;;
esac

# System package manager (Linux) — defines the suggested commands
PKG=""
if [[ $OS == linux ]]; then
  if   command -v apt-get >/dev/null 2>&1; then PKG=apt
  elif command -v dnf     >/dev/null 2>&1; then PKG=dnf
  elif command -v pacman  >/dev/null 2>&1; then PKG=pacman
  fi
fi

# Equivalent directories on the two platforms
if [[ $OS == macos ]]; then
  CACHE_DIR="$HOME/Library/Caches"
  APPDATA_DIR="$HOME/Library/Application Support"
  # On macOS we don't limit find to one filesystem: CloudStorage and volumes
  # mounted inside the home may be exactly what is taking up space.
  XDEV=""
else
  CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
  APPDATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
  # On Linux the home often has foreign mounts (gvfs, NFS, external disk);
  # -xdev avoids scanning what isn't a local disk.
  XDEV="-xdev"
fi

# Downloads folder (honors XDG on Linux)
DOWNLOADS_DIR="$HOME/Downloads"
if [[ $OS == linux ]] && command -v xdg-user-dir >/dev/null 2>&1; then
  _xdg_dl=$(xdg-user-dir DOWNLOAD 2>/dev/null || true)
  if [[ -n "${_xdg_dl:-}" && -d "${_xdg_dl:-}" && "${_xdg_dl:-}" != "$HOME" ]]; then
    DOWNLOADS_DIR="$_xdg_dl"
  fi
fi

# No TTY → no color
[[ -t 1 ]] || USE_COLOR=0

# The menu only makes sense with someone on the other side (stdin and stdout on a terminal)
[[ -t 0 && -t 1 ]] || MENU=0

# Items below this are dropped from the report lists (noise)
MIN_LIST_KB=10240        # 10 MB
# and, in the summary, become one "+N smaller items" line per risk level
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

# Shortens a path for display: /home/foo/.cache → ~/.cache
# (the '~' comes from a variable: escaped as \~, macOS's bash 3.2 keeps the backslash)
tilde() {
  local t='~'
  printf '%s\n' "${1/#$HOME/$t}"
}

# Runs a command in the background with a spinner on stderr.
# Buffers stdout and dumps it only when done
# (keeps the spinner on a single line, no interleaving).
# Without a TTY or with color disabled, runs directly with no spinner.
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

# In summary mode the report goes to a file; a status line on stderr
# says which part of the scan we are in (the spinners draw over it)
SHOW_STATUS=0
[[ $FULL -eq 0 && $USE_COLOR -eq 1 && -t 2 ]] && SHOW_STATUS=1
STATUS_MSG=""
status() {
  [[ $SHOW_STATUS -eq 1 ]] || return 0
  STATUS_MSG="$1"
  printf '\r\033[K  %s⠿%s scanning: %s' "$C_CYAN" "$C_RESET" "$STATUS_MSG" >&2
}

# ----- Opportunity registry (for the final ranking) -----
OPPS_FILE=$(mktemp)
BLIND_FILE=$(mktemp)   # what was left out of the count (no root, daemon stopped...)
FULL_OUT=$(mktemp)     # full report, section by section

# Risk levels:
#   SAFE     — regenerates on its own (cache, build artifact, trash)
#   MODERATE — can be freed, but costs a re-download/rebuild
#   REVIEW   — potential data loss; manual decision
#
# register_opp <bytes> <risk> <path-or-empty> <description> <command>
# path is used to deduplicate overlapping items in the final ranking.
# Silently ignored if bytes is empty/zero/invalid.
register_opp() {
  local bytes="$1" risk="$2" path="$3" desc="$4" cmd="$5"
  [[ -z "$bytes" || ! "$bytes" =~ ^[0-9]+$ || "$bytes" -le 0 ]] && return 0
  printf '%s\t%s\t%s\t%s\t%s\n' "$bytes" "$risk" "$path" "$desc" "$cmd" >> "$OPPS_FILE"
}

# Configuration tweak (cache limit, ext4 reserve...): not counted in the
# per-risk totals, but shows up in the summary and can be run from the menu.
# register_tip <bytes-or-0> <description> <command>
register_tip() {
  local bytes="${1:-0}"
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
  printf '%s\t%s\t%s\t%s\t%s\n' "$bytes" "TWEAK" "" "$2" "$3" >> "$OPPS_FILE"
}

# register_blind <text> — something the scan could not measure
register_blind() {
  printf '%s\n' "$1" >> "$BLIND_FILE"
}

# A path that can go inside double quotes in a command without changing its
# meaning. Suggested commands interpolate paths from disk and the menu runs
# them: a folder name with quotes, $ or a backtick would turn into code.
shell_safe() {
  case "$1" in
    *[\"\$\`\\]*|*$'\n'*) return 1 ;;
  esac
  return 0
}

# Caches that must NOT be deleted blindly: they hold iCloud/system state
# and deleting them triggers a re-sync or odd behavior.
RISKY_CACHE_RE='com\.apple\.bird|CloudDocs|com\.apple\.cloudd|com\.apple\.Safari|com\.apple\.homed|FamilyCircle'

# Refines the risk/command of a known cache item (used by the cache
# sections). Echoes "risk<TAB>command" when it knows the item; nothing when
# it doesn't — then the caller keeps the section's generic one.
refine_cache_item() {
  local path="$1" base clones
  base=$(basename "$path")
  if [[ $OS == macos && "$base" =~ $RISKY_CACHE_RE ]]; then
    printf 'REVIEW\t%s\n' "# iCloud/system cache — deleting it may trigger a re-sync; let macOS manage it"
    return 0
  fi
  refine_known_cache "$path" "$base" && return 0
  # Git clones left in the cache (scripts that clone repositories to
  # analyze them) don't come back on their own like an app cache: only by cloning again.
  # Checked after the known ones: Homebrew, pre-commit and Nix also keep
  # clones, but redo them on their own.
  clones=$(count_git_repos "$path")
  if [[ $clones -gt 0 ]]; then
    printf 'MODERATE\t%s\n' "rm -rf \"$path\"  # $clones git repo(s): only come back by cloning again — check nothing still uses them"
  fi
  return 0
}

# Git repositories up to 2 levels below a directory: with .git (normal
# clone) or bare (HEAD + objects/ + refs/ right in the folder, as left by
# git clone --bare)
count_git_repos() {
  find "$1" -mindepth 1 -maxdepth 3 \( -name .git -o -name HEAD -type f \) 2>/dev/null \
    | while IFS= read -r g; do
        case "$g" in
          */.git) echo "$g" ;;
          */.git/HEAD) ;;   # the HEAD inside a .git was already counted
          */HEAD) [[ -d "${g%/HEAD}/objects" && -d "${g%/HEAD}/refs" ]] && echo "$g" ;;
        esac
      done \
    | wc -l | tr -d ' '
}

# Caches with their own cleanup command (better than a generic rm -rf).
# The names apply on both platforms (~/.cache and ~/Library/Caches).
# Returns 1 when it doesn't know the item.
refine_known_cache() {
  local path="$1" base="$2"
  case "$base" in
    pip)            printf 'SAFE\t%s\n'     "pip cache purge" ;;
    uv)             printf 'SAFE\t%s\n'     "uv cache clean" ;;
    yarn)           printf 'SAFE\t%s\n'     "yarn cache clean" ;;
    go-build)       printf 'SAFE\t%s\n'     "go clean -cache" ;;
    ms-playwright)  printf 'SAFE\t%s\n'     "npx playwright uninstall --all" ;;
    Homebrew)       printf 'SAFE\t%s\n'     "brew cleanup -s --prune=all" ;;
    tracker3)
      if command -v localsearch >/dev/null 2>&1; then
        printf 'SAFE\t%s\n' "localsearch reset -s  # GNOME search index; reindexes on its own"
      else
        printf 'SAFE\t%s\n' "tracker3 reset -s  # GNOME search index; reindexes on its own"
      fi ;;
    thumbnails)     printf 'SAFE\t%s\n'     "rm -rf \"$path\"  # file manager thumbnails; regenerate" ;;
    JetBrains)      printf 'SAFE\t%s\n'     "rm -rf \"$path\"  # IDE caches/indexes; reindex on open" ;;
    mesa_shader_cache|mesa_shader_cache_db|nvidia|fontconfig)
                    printf 'SAFE\t%s\n'     "rm -rf \"$path\"  # GPU/font cache; regenerates on its own" ;;
    google-chrome|chromium|BraveSoftware|microsoft-edge|vivaldi|mozilla)
                    printf 'SAFE\t%s\n'     "rm -rf \"$path\"  # browser cache (close the app first)" ;;
    huggingface)    printf 'MODERATE\t%s\n' "rm -rf \"$path/hub\"  # models re-download when used" ;;
    pre-commit)     printf 'MODERATE\t%s\n' "pre-commit clean" ;;
    bazel|bazelisk) printf 'MODERATE\t%s\n' "bazel clean --expunge  # a rebuild redoes everything" ;;
    nix)            printf 'SAFE\t%s\n'     "rm -rf \"$path\"  # Nix download cache; re-downloads on its own" ;;
    *) return 1 ;;
  esac
  return 0
}

# App data items that another section measures more precisely: echoes
# "-<TAB>note" (shows in the list, but isn't registered — otherwise the
# ranking dedup swallows the specific line, which is smaller than the whole folder)
refine_appdata_item() {
  [[ $OS == linux ]] || return 0
  case "$(basename "$1")" in
    claude) printf -- '-\t%s\n' "Claude Code: only old versions count, in the dev caches section" ;;
  esac
  return 0
}

# Converts a string like "7.3GB", "34.6 MB", "1.8GB (72%)" to bytes.
# $2 = "si" for decimal units (Docker/Podman: 1 GB = 10^9 bytes);
# without it, binary (Homebrew, journalctl)
parse_size_to_bytes() {
  awk -v s="$1" -v si="${2:-}" 'BEGIN {
    n = s + 0   # leading numeric part
    k = (si == "si") ? 1000 : 1024
    if (s ~ /[Tt]B?/) mult = k * k * k * k
    else if (s ~ /[Gg]B?/) mult = k * k * k
    else if (s ~ /[Mm]B?/) mult = k * k
    else if (s ~ /[Kk]B?/) mult = k
    else mult = 1
    printf "%d\n", n * mult
  }'
}

# Sums a column of '<docker|podman> system df' in bytes (Size, Reclaimable)
container_df_bytes() {
  "$1" system df --format "{{.$2}}" 2>/dev/null \
    | while IFS= read -r line; do
        # each line: "1.8GB (72%)" or "0B"
        parse_size_to_bytes "${line%% *}" si
      done \
    | awk '{s+=$1} END {print s+0}'
}

# Clears the spinner and temp files on exit (a single trap; INT/TERM
# become exit so they don't override the cleanup in --report mode)
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

# Section that only shows up when its body prints something — no "nothing
# found" taking up the screen. The body runs in a subshell: it registers
# opportunities normally (they go to a file), but variables it sets don't come back.
# section_if <title> <function> [args...]
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

# Lists the top N children of a directory by size
top_children() {
  local dir="$1"
  local n="${2:-$TOP_N}"
  [[ -d "$dir" ]] || { note "  (does not exist: $dir)"; return; }
  # du -k + human_bytes (not du -h, which rounds up): the same directory
  # shows the same number in every section
  du -sk "$dir"/* "$dir"/.[!.]* 2>/dev/null \
    | sort -rn \
    | awk -F'\t' -v min="$MIN_LIST_KB" '$1 >= min' \
    | head -n "$n" \
    | while IFS=$'\t' read -r kb path; do
        printf '  %8s  %s%s%s\n' "$(human_bytes $((kb * 1024)))" "$C_DIM" "$path" "$C_RESET"
      done
}

# Like top_children, but also registers each entry as an opportunity.
# $3 = risk, $4 = label (description prefix), $5 = command template ({} = path)
top_children_register() {
  local dir="$1" n="${2:-$TOP_N}" risk="$3" label="$4" cmd_tpl="$5"
  [[ -d "$dir" ]] || { note "  (does not exist: $dir)"; return; }
  du -sk "$dir"/* "$dir"/.[!.]* 2>/dev/null \
    | sort -rn \
    | awk -F'\t' -v min="$MIN_LIST_KB" '$1 >= min' \
    | head -n "$n" \
    | while IFS=$'\t' read -r kb path; do
        [[ -z "$kb" || -z "$path" ]] && continue
        local bytes=$((kb * 1024))
        local item_risk="$risk" cmd="${cmd_tpl//\{\}/$path}" refined="" tag=""
        # Known items get a more precise risk/command
        if [[ "$item_risk" == "SAFE" ]]; then
          refined=$(refine_cache_item "$path")
        elif [[ "$dir" == "$APPDATA_DIR" ]]; then
          refined=$(refine_appdata_item "$path")
        fi
        if [[ -n "$refined" ]]; then
          item_risk="${refined%%$'\t'*}"
          cmd="${refined#*$'\t'}"
          if [[ "$item_risk" == "-" ]]; then
            tag="  ($cmd)"   # note on where the item is really measured
          elif [[ "$item_risk" != "$risk" ]]; then
            tag="  [$item_risk]"
          fi
        fi
        printf '  %8s  %s%s%s%s\n' "$(human_bytes "$bytes")" "$C_DIM" "$path" "$tag" "$C_RESET"
        [[ "$item_risk" == "-" ]] && continue
        register_opp "$bytes" "$item_risk" "$path" "$label: $(basename "$path")" "$cmd"
      done
}

# Looks for big files (>=MIN MB) in a directory, with limited depth
big_files() {
  local dir="$1"
  local min_mb="${2:-500}"
  local depth="${3:-4}"
  local n="${4:-$TOP_N}"
  [[ -d "$dir" ]] || return
  # -exec instead of xargs: with no results, GNU xargs runs 'du' with no
  # arguments and measures the current directory
  # shellcheck disable=SC2086  # $XDEV is a single flag (or empty)
  find "$dir" $XDEV -maxdepth "$depth" -type f -size +"${min_mb}"M -exec du -k {} + 2>/dev/null \
    | sort -rn \
    | head -n "$n" \
    | while IFS=$'\t' read -r kb f; do
        printf '  %8s  %s%s%s\n' "$(human_bytes $((kb * 1024)))" "$C_DIM" "$f" "$C_RESET"
      done
}

# Like big_files, but measures in KB and registers each file as an opportunity
big_files_register() {
  local dir="$1" min_mb="$2" depth="$3" n="$4" risk="$5" label="$6"
  [[ -d "$dir" ]] || return 0
  local found
  # shellcheck disable=SC2086
  found=$(find "$dir" $XDEV -maxdepth "$depth" -type f -size +"${min_mb}"M -exec du -k {} + 2>/dev/null \
    | sort -rn | head -n "$n")
  if [[ -z "$found" ]]; then
    note "  (no files over ${min_mb} MB)"
    return 0
  fi
  while IFS=$'\t' read -r kb f; do
    [[ -z "$kb" || -z "$f" ]] && continue
    printf '  %8s  %s%s%s\n' "$(human_bytes $((kb * 1024)))" "$C_DIM" "$f" "$C_RESET"
    register_opp "$((kb * 1024))" "$risk" "$f" "$label: $(basename "$f")" "# review: $f"
  done <<< "$found"
}

# under_any <path> <roots, one per line> — is path inside any of the roots?
under_any() {
  local root
  while IFS= read -r root; do
    [[ -n "$root" && "$1" == "$root"/* ]] && return 0
  done <<< "$2"
  return 1
}

# Lists the 10 biggest folders of a group (one per line) and leaves the total
# in GROUP_COUNT/GROUP_BYTES for the caller to register
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
  # Total in a single call: du counts hardlinks once (pnpm's node_modules
  # point to the store, and adding folder by folder would inflate the number)
  kb=$(printf '%s' "$list" | tr '\n' '\0' | xargs -0 du -skc 2>/dev/null \
    | awk -F'\t' '$2 == "total" { s += $1 } END { print s + 0 }')
  GROUP_BYTES=$((kb * 1024))
}

# A single pass over $HOME looking for project junk: node_modules, build
# artifacts and git worktrees. Skips the hidden folders at the top of the
# home (tool caches have their own section, and the global node_modules of
# nvm/mise is not disposable) and app areas (~/Library, ~/snap).
# Worktrees count whole as REVIEW; what is inside them is not counted
# again in the node_modules/builds totals.
scan_projects() {
  local list p gitdir wts="" nm_list="" art_list="" kb wt main ct days dirty info now wt_cmd
  # shellcheck disable=SC2086
  list=$(find "$HOME" $XDEV \
      \( -path "$HOME/.*" -o -path "$HOME/Library" -o -path "$HOME/snap" -o -path "$HOME/go/pkg" \
         -o \( -name .git -type d \) \) -prune -o \
      \( -type d \( -name node_modules -o -name .next -o -name .nuxt -o -name .svelte-kit \
                   -o -name .turbo -o -name .parcel-cache -o -name target \) -prune -print \) -o \
      \( -type f -name .git -print \) 2>/dev/null)

  # In a worktree .git is a file "gitdir: <repo>/.git/worktrees/<name>"
  # (in a submodule it's also a file, but it points to .git/modules)
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
      target)  # Rust/Maven builds only; 'target' is too common a name
        [[ -f "$(dirname "$p")/Cargo.toml" || -f "$(dirname "$p")/pom.xml" ]] && art_list+="$p"$'\n' ;;
      *) art_list+="$p"$'\n' ;;
    esac
  done <<< "$list"

  note "node_modules (top 10):"
  if [[ -n "$nm_list" ]]; then
    dir_group "$nm_list"
    out "  ${C_BOLD}Total: ${GROUP_COUNT} folder(s), $(human_bytes "$GROUP_BYTES")${C_RESET}"
    register_opp "$GROUP_BYTES" "SAFE" "" "node_modules: ${GROUP_COUNT} project folder(s)" \
      "rm -rf <project>/node_modules  # in idle projects; npm/pnpm install brings it back"
  else
    note "  (none)"
  fi

  if [[ -n "$art_list" ]]; then
    out ""
    note "Build artifacts (.next, .turbo, Rust/Maven target/...) — top 10:"
    dir_group "$art_list"
    out "  ${C_BOLD}Total: ${GROUP_COUNT} folder(s), $(human_bytes "$GROUP_BYTES")${C_RESET}"
    register_opp "$GROUP_BYTES" "SAFE" "" "Build artifacts: ${GROUP_COUNT} folder(s)" \
      "rm -rf <folder>  # the next build regenerates it (Rust: cargo clean; Maven: mvn clean)"
  fi

  if [[ -n "$wts" ]]; then
    out ""
    note "Git worktrees (each one is a full checkout, with its own node_modules):"
    now=$(date +%s)
    while IFS= read -r wt; do
      [[ -n "$wt" ]] && du -sk "$wt" 2>/dev/null
    done <<< "$wts" \
      | sort -rn \
      | while IFS=$'\t' read -r kb wt; do
          gitdir=$(sed -n 's/^gitdir: //p' "$wt/.git" 2>/dev/null)
          [[ "$gitdir" == /* ]] || gitdir="$wt/$gitdir"   # git >= 2.48 accepts a relative path
          main="${gitdir%/worktrees/*}"; main="${main%/.git}"
          ct=$(git -C "$wt" log -1 --format=%ct 2>/dev/null)
          days=$(( (now - ${ct:-$now}) / 86400 ))
          # --no-optional-locks: status doesn't rewrite .git/index (read-only)
          dirty=$(git -C "$wt" --no-optional-locks status --porcelain 2>/dev/null | wc -l)
          if [[ $days -eq 0 ]]; then info="last commit today"; else info="last commit ${days}d ago"; fi
          info+=", $((dirty + 0)) local change(s)"
          printf '  %8s  %s%s%s  %s(%s)%s\n' "$(human_bytes $((kb * 1024)))" \
            "$C_DIM" "$wt" "$C_RESET" "$C_DIM" "$info" "$C_RESET"
          wt_cmd="git -C \"$main\" worktree remove \"$wt\"  # --force discards local changes"
          shell_safe "$main" || wt_cmd="# remove it with git: $wt_cmd"
          register_opp "$((kb * 1024))" "REVIEW" "$wt" "Git worktree: $(basename "$wt") ($info)" "$wt_cmd"
        done
  fi
}

# Internal breakdown line + registration (used by detail_dev_cache).
# detail_item <path> <risk> <description> <command>
detail_item() {
  local path="$1" risk="$2" desc="$3" cmd="$4"
  [[ -e "$path" ]] || return 0
  local kb; kb=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
  local bytes=$(( ${kb:-0} * 1024 ))
  [[ $bytes -gt 0 ]] || return 0
  local tag_color="$C_RED"
  [[ "$risk" == "SAFE" ]] && tag_color="$C_GREEN"
  [[ "$risk" == "MODERATE" ]] && tag_color="$C_YELLOW"
  printf '  %8s    ↳ %s[%s]%s %s%s%s\n' "$(human_bytes "$bytes")" \
    "$tag_color" "$risk" "$C_RESET" "$C_DIM" "$desc" "$C_RESET"
  register_opp "$bytes" "$risk" "$path" "$desc" "$cmd"
  return 0
}

# Internal breakdown of known dev caches (--detail mode).
# Registers opportunities per subfolder — more precise than the whole dir
# (e.g. inside ~/.npm, _cacache is SAFE; inside ~/.cargo, the
# registry is MODERATE but bin/ holds installed binaries).
# Returns 1 when it doesn't know the dir → the caller registers the generic one.
detail_dev_cache() {
  local key="$1" p="$2"
  case "$key" in
    .npm)
      detail_item "$p/_cacache" "SAFE" "npm cache (~/.npm/_cacache)" "npm cache clean --force"
      detail_item "$p/_npx"     "SAFE" "npx packages (~/.npm/_npx)"  "rm -rf \"$p/_npx\"  # reinstalled when used"
      ;;
    Library/pnpm|.local/share/pnpm)
      detail_item "$p/store" "MODERATE" "pnpm store" "pnpm store prune  # removes only orphaned packages"
      [[ -d "$p/store" ]] && note "              tip: delete node_modules of dead projects before the prune"
      ;;
    .gradle)
      detail_item "$p/caches"        "MODERATE" "Gradle caches"                  "rm -rf \"$p/caches\"  # a rebuild downloads them again"
      detail_item "$p/wrapper/dists" "MODERATE" "Gradle wrapper (distributions)" "# keep only the version in use: ls \"$p/wrapper/dists\""
      ;;
    .cache)
      detail_item "$p/pip"           "SAFE"     "pip cache"           "pip cache purge"
      detail_item "$p/uv"            "SAFE"     "uv cache"            "uv cache clean"
      detail_item "$p/huggingface"   "MODERATE" "HuggingFace models"  "rm -rf \"$p/huggingface/hub\"  # models re-download when used"
      detail_item "$p/ms-playwright" "SAFE"     "Playwright browsers" "npx playwright uninstall --all"
      ;;
    .cargo)
      detail_item "$p/registry" "MODERATE" "cargo registry" "rm -rf \"$p/registry\"  # re-downloaded on the next build"
      detail_item "$p/git"      "MODERATE" "cargo git deps" "rm -rf \"$p/git\""
      ;;
    *) return 1 ;;
  esac
  return 0
}

# On Linux, system areas (/var/lib/docker, journal, crashes) are only
# readable as root — without sudo the report undercounts all the same.
system_dirs_readable() {
  local probe
  for probe in /var/lib/docker /var/log/journal /var/crash /var/lib/systemd/coredump /root; do
    [[ -d "$probe" ]] || continue
    ls "$probe" >/dev/null 2>&1 || return 1
  done
  return 0
}

# OS name for the report header
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

# "X used of Y (Z%) — free: W" line for a filesystem
# fs_summary <path> <label>
fs_summary() {
  local target="$1" label="$2" size_kb used_kb avail_kb pct extra=""
  read -r size_kb used_kb avail_kb <<< "$(df -Pk "$target" 2>/dev/null | awk 'NR==2 {print $2, $3, $4}')"
  [[ "${size_kb:-0}" -gt 0 ]] || return 0
  if [[ $OS == macos ]]; then
    # APFS: df's "used" is only this volume; the whole container is size - avail
    used_kb=$((size_kb - avail_kb))
  else
    # ext4 reserves blocks for root (5% by default): neither used nor free
    local reserved_kb=$((size_kb - used_kb - avail_kb))
    [[ $reserved_kb -gt 0 ]] && extra=" — reserved for root: $(human_bytes $((reserved_kb * 1024)))"
  fi
  # Rounds up, like df's Use% (otherwise the line above says 99% and this one 98%)
  local denom=$(( used_kb + avail_kb > 0 ? used_kb + avail_kb : 1 ))
  pct=$(( (used_kb * 100 + denom - 1) / denom ))
  out "  ${C_BOLD}${label}: $(human_bytes $((used_kb * 1024))) used of $(human_bytes $((size_kb * 1024))) (${pct}%) — free: $(human_bytes $((avail_kb * 1024)))${extra}${C_RESET}"
}

# Same filesystem? (Downloads may be a link to a host folder in a VM, to an
# external disk or the network — deleting there frees nothing on the home disk)
same_fs() {
  [[ "$(df -P "$1" 2>/dev/null | awk 'NR==2 {print $1}')" == \
     "$(df -P "$2" 2>/dev/null | awk 'NR==2 {print $1}')" ]]
}

# Measures a system directory, prints the line and registers the opportunity.
# Silent when the directory doesn't exist or is empty.
# Risk "-" only prints (when another line already registers that space).
# sys_report_dir <path> <risk> <description> <command>
sys_report_dir() {
  local path="$1" risk="$2" desc="$3" cmd="$4" kb bytes
  [[ -d "$path" ]] || return 0
  # Without permission du measures only the directory entry (4 KB) — a fake number.
  # Says it couldn't be measured; if another line already covers that space, not even that.
  if [[ ! -r "$path" || ! -x "$path" ]]; then
    [[ "$risk" == "-" ]] || printf '  %8s  %s  %s(root only)%s\n' "?" "$path" "$C_DIM" "$C_RESET"
    return 0
  fi
  kb=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
  [[ ${kb:-0} -ge $MIN_LIST_KB ]] || return 0
  bytes=$((kb * 1024))
  printf '  %8s  %s\n' "$(human_bytes "$bytes")" "$path"
  [[ "$risk" == "-" ]] || register_opp "$bytes" "$risk" "$path" "$desc" "$cmd"
}

# Where the trash folders are (the user's + those of volumes/removable media)
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

# Command to empty the trash on the current platform
empty_trash_cmd() {
  if [[ $OS == macos ]]; then
    printf '%s\n' "osascript -e 'tell application \"Finder\" to empty trash'"
  elif command -v gio >/dev/null 2>&1; then
    printf '%s\n' "gio trash --empty"
  else
    printf '%s\n' "rm -rf \"$APPDATA_DIR/Trash\"/files/* \"$APPDATA_DIR/Trash\"/info/*"
  fi
}

# Without Full Disk Access, du fails silently in TCC-protected areas
# (Mail, Messages, Safari) and the report undercounts. Detected by probing one of them.
has_full_disk_access() {
  local probe
  for probe in "$HOME/Library/Mail" "$HOME/Library/Messages" "$HOME/Library/Safari"; do
    [[ -e "$probe" ]] || continue
    ls "$probe" >/dev/null 2>&1
    return $?
  done
  return 0
}

# Human-readable bytes from raw bytes
human_bytes() {
  local b="$1"
  awk -v b="$b" 'BEGIN{
    split("B KB MB GB TB PB", u);
    i=1; while(b>=1024 && i<6){ b/=1024; i++ }
    printf "%.1f %s\n", b, u[i]
  }'
}

# =============================================================================
# PLATFORM-SPECIFIC SECTIONS
# =============================================================================

# --- Disk overview ------------------------------------------------------------

disk_overview_macos() {

# On modern macOS "/" is the sealed system volume (small, read-only);
# user data lives in /System/Volumes/Data, in the same APFS container,
# and free space is shared by all volumes. Looking only at "/"
# (greatly) underestimates real disk usage.
DATA_VOL="/System/Volumes/Data"
[[ -d "$DATA_VOL" ]] || DATA_VOL="/"
df -h / "$DATA_VOL" 2>/dev/null \
  | awk 'NR==1 { printf "  %s\n", $0; next } !seen[$1]++ { printf "  %s\n", $0 }'

out ""
fs_summary "$DATA_VOL" "APFS container"
note "  Your files count against the Data volume. Finder may show more free space"
note "  because it includes 'purgeable' space (snapshots, caches macOS drops on its own)."

# Extra APFS volumes (snapshots live here)
out ""
note "APFS volumes (includes snapshots and local Time Machine):"
df -h | awk '/^\/dev\/disk/ && $1 !~ /\/dev\/null/ { printf "  %-25s  used=%s  avail=%s  %s\n", $1, $3, $4, $9 }'

}

disk_overview_linux() {

# Real filesystems only: no tmpfs/devtmpfs (RAM), squashfs (each mounted snap
# shows up as a device) or overlay (containers).
df -hT -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs -x fuse.gvfsd-fuse 2>/dev/null \
  | awk 'NR==1 { printf "  %s\n", $0; next } !seen[$1]++ { printf "  %s\n", $0 }'

out ""
fs_summary / "Root (/)"

# $HOME on a separate filesystem (a dedicated /home is common) → show both
home_fs=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print $1}')
root_fs=$(df -Pk / 2>/dev/null | awk 'NR==2 {print $1}')
if [[ -n "$home_fs" && "$home_fs" != "$root_fs" ]]; then
  fs_summary "$HOME" "\$HOME"
fi

# A full /boot is the classic "apt upgrade failed" — almost always old kernels
if [[ "$(df -Pk /boot 2>/dev/null | awk 'NR==2 {print $6}')" == "/boot" ]]; then
  fs_summary /boot "/boot"
  boot_pct=$(df -Pk /boot 2>/dev/null | awk 'NR==2 { gsub(/%/, "", $5); print $5 }')
  if [[ "${boot_pct:-0}" -ge 80 ]]; then
    out "  ${C_YELLOW}⚠ /boot at ${boot_pct}% — old kernels are usually the cause;"
    out "    see the 'System' section further down.${C_RESET}"
  fi
fi

root_fstype=$(df -PT / 2>/dev/null | awk 'NR==2 {print $2}')
case "$root_fstype" in
  btrfs|zfs)
    note "  Root on ${root_fstype}: snapshots share space with the live files —"
    note "  deleting a file frees nothing while a snapshot still references it."
    ;;
  ext4)
    # Disk almost full + big reserve: lowering it to 1% gives space back to the user
    read -r r_dev r_size r_used r_avail <<< "$(df -Pk / 2>/dev/null | awk 'NR==2 {print $1, $2, $3, $4}')"
    r_reserved=$(( ${r_size:-0} - ${r_used:-0} - ${r_avail:-0} ))
    r_gain=$(( r_reserved - ${r_size:-0} / 100 ))   # current reserve - 1%
    if [[ $r_gain -ge 1048576 && $(( ${r_used:-0} * 100 / (${r_used:-0} + ${r_avail:-0} + 1) )) -ge 80 ]]; then
      r_pct=$(( (r_reserved * 100 + r_size / 2) / r_size ))
      out "  ${C_YELLOW}Tip:${C_RESET} the root ext4 reserves $(human_bytes $((r_reserved * 1024))) for root only. 1% is plenty:"
      out "    ${C_BOLD}sudo tune2fs -m 1 $r_dev${C_RESET}   ${C_DIM}# frees ~$(human_bytes $((r_gain * 1024))) for the user${C_RESET}"
      shell_safe "$r_dev" && register_tip $((r_gain * 1024)) "ext4 root reserve on /: ${r_pct}% → 1%" \
        "sudo tune2fs -m 1 $r_dev  # gives space back to the user; undo with: sudo tune2fs -m ${r_pct} $r_dev"
    fi
    ;;
esac

# Swapfile: takes up disk without showing in any folder
sw_any=0
while read -r sw_name sw_type sw_size sw_used; do
  [[ "$sw_type" == file ]] || continue
  [[ $sw_any -eq 0 ]] && out ""
  sw_any=1
  out "  Swapfile ${sw_name}: $(human_bytes "${sw_size:-0}") (in use: $(human_bytes "${sw_used:-0}"))"
done < <(swapon --show=NAME,TYPE,SIZE,USED --noheadings --bytes 2>/dev/null)
[[ $sw_any -eq 1 ]] && note "  Only worth shrinking if you have plenty of spare RAM (see 'free -h')."

}

# --- Root: where the space went (Linux) ---------------------------------------

# Children of a directory on the same filesystem as the root (no symlinks and
# no mounts like /proc, /boot or /media)
# root_children <dir> <root device>
root_children() {
  find "$1" -mindepth 1 -maxdepth 1 -printf '%D\t%y\t%p\n' 2>/dev/null \
    | awk -F'\t' -v dev="$2" '$1 == dev && $2 != "l" { print $3 }'
}

# Short note for the known folders in the root map
root_leaf_note() {
  case "$1" in
    "$HOME")                             echo "your home — broken down in the sections below" ;;
    /usr)                                echo "installed software — biggest packages in the System section" ;;
    /var/lib/docker|/var/lib/containerd) echo "Docker" ;;
    /var/lib/containers)                 echo "Podman" ;;
    /var/lib/snapd)                      echo "snaps — broken down in the System section" ;;
    /var/lib/flatpak)                    echo "Flatpak" ;;
    /var/log)                            echo "logs" ;;
    /var/cache)                          echo "system caches" ;;
    /home/linuxbrew)                     echo "Homebrew" ;;
    /root)                               echo "root's home" ;;
    *) printf '%s\n' "$ROOT_SWAPS" | grep -qxF -- "$1" && echo "swap" ;;
  esac
  return 0
}

root_map_linux() {

section "Root (/) — where the space went"
# Measures the root filesystem per folder and reconciles it with df's "used".
# Folders that just group unrelated things go one level down (/var/lib, two),
# otherwise /var or /home would hide Docker, snapd and Homebrew.
rm_dev=$(stat -c %d / 2>/dev/null)
ROOT_SWAPS=$(swapon --show=NAME,TYPE --noheadings 2>/dev/null | awk '$2 == "file" {print $1}')
rm_leaves=()
rm_locked=""   # folders the user can't read: du would measure only 4 KB
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

# A single du: hardlinks (e.g. the snapd cache) count once
rm_du=$(run_spun "measuring the root (/)... (may take a while)" du -xsk "${rm_leaves[@]}" 2>/dev/null)
sort -rn <<< "$rm_du" | head -n "$TOP_N" \
  | while IFS=$'\t' read -r kb p; do
      [[ -n "$kb" ]] || continue
      rm_note=$(root_leaf_note "$p")
      printf '  %8s  %s%s\n' "$(human_bytes $((kb * 1024)))" "$p" \
        "${rm_note:+  ${C_DIM}($rm_note)${C_RESET}}"
    done

# Unreadable: only the known ones get a line; the rest becomes a count
rm_locked_other=0
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  rm_note=$(root_leaf_note "$p")
  if [[ -n "$rm_note" ]]; then
    printf '  %8s  %s  %s(%s — root only)%s\n' "?" "$p" "$C_DIM" "$rm_note" "$C_RESET"
  else
    rm_locked_other=$((rm_locked_other + 1))
  fi
done <<< "$rm_locked"
[[ $rm_locked_other -gt 0 ]] && note "         +${rm_locked_other} system folder(s) only root can read"

rm_measured_kb=$(awk -F'\t' '{s += $1} END {print s+0}' <<< "$rm_du")
rm_used_kb=$(df -Pk / 2>/dev/null | awk 'NR==2 {print $3}')
rm_gap_kb=$(( ${rm_used_kb:-0} - rm_measured_kb ))
out ""
out "  ${C_BOLD}Measured: $(human_bytes $((rm_measured_kb * 1024))) of $(human_bytes $(( ${rm_used_kb:-0} * 1024 ))) used on /${C_RESET}"
# Under 1 GB the difference is noise (metadata, files changing during du)
[[ $rm_gap_kb -ge 1048576 ]] || return 0
if [[ $EUID -ne 0 ]]; then
  out "  ${C_YELLOW}$(human_bytes $((rm_gap_kb * 1024))) unaccounted for: folders only root can read (the ones marked ? and parts of others).${C_RESET}"
  if command -v docker >/dev/null 2>&1; then
    rm_docker=$(container_df_bytes docker Size)
    [[ ${rm_docker:-0} -gt 0 ]] && \
      note "  Docker reports $(human_bytes "$rm_docker") in 'docker system df' — usually the bulk of it."
  fi
  note "  To account for everything (still read-only): sudo HOME=\"$HOME\" $0"
  register_blind "$(human_bytes $((rm_gap_kb * 1024))) of the root is in folders only root can read (Docker, /root, journal) — to count it: sudo HOME=\"$HOME\" $0"
else
  out "  ${C_YELLOW}$(human_bytes $((rm_gap_kb * 1024))) in use that no folder accounts for.${C_RESET}"
  note "  Deleted files that some process still holds open (the space only comes back when it closes them):"
  out "    ${C_BOLD}sudo lsof -nP +L1 | awk 'NR == 1 || \$7 > 104857600'${C_RESET}   ${C_DIM}# >100 MB; restart the process${C_RESET}"
  note "  Or files hidden under a mount point (written before the disk was mounted)."
  register_tip 0 "$(human_bytes $((rm_gap_kb * 1024))) in use that no folder accounts for: deleted files still open?" \
    "sudo lsof -nP +L1 | awk 'NR == 1 || \$7 > 104857600'  # only lists; the space comes back when you restart the process holding the file"
fi

}

# --- Local snapshots ----------------------------------------------------------

# section_if bodies: print nothing when there are no snapshots

snapshots_macos() {

if command -v tmutil >/dev/null 2>&1; then
  snaps=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c "com.apple.TimeMachine" || true)
  if [[ "$snaps" -gt 0 ]]; then
    note "(Usually invisible in Finder, but they take up GBs)"
    out "  ${C_YELLOW}${snaps} local snapshot(s) found${C_RESET}"
    tmutil listlocalsnapshots / 2>/dev/null | sed 's/^/    /'
    out ""
    out "  ${C_GREEN}To remove the oldest ones (frees GBs):${C_RESET}"
    out "    ${C_BOLD}sudo tmutil thinlocalsnapshots / 999999999999 4${C_RESET}"
    register_tip 0 "${snaps} local Time Machine snapshot(s) (size not reported)" \
      "sudo tmutil thinlocalsnapshots / 999999999999 4  # macOS also deletes them on its own when the disk gets tight"
  fi
fi

}

snapshots_linux() {

snap_found=0

# ZFS — Ubuntu's default install with "Erase disk and use ZFS" creates
# automatic snapshots on every apt upgrade (zsys); they pile up to tens of GB.
if command -v zfs >/dev/null 2>&1; then
  zfs_bytes=$(zfs list -H -p -t snapshot -o used 2>/dev/null | awk '{s+=$1} END {print s+0}')
  zfs_count=$(zfs list -H -t snapshot -o name 2>/dev/null | grep -c . || true)
  if [[ "${zfs_count:-0}" -gt 0 ]]; then
    snap_found=1
    out "  ${C_YELLOW}${zfs_count} ZFS snapshot(s) — $(human_bytes "${zfs_bytes:-0}") in total${C_RESET}"
    zfs list -H -t snapshot -o name,used -s used 2>/dev/null | tail -10 \
      | awk -F'\t' '{ printf "    %8s  %s\n", $2, $1 }'
    out ""
    out "  ${C_GREEN}To inspect and delete:${C_RESET}"
    out "    ${C_BOLD}zfs list -t snapshot -o name,used -s used${C_RESET}"
    out "    ${C_BOLD}sudo zfs destroy <dataset>@<snapshot>${C_RESET}   ${C_DIM}# one at a time${C_RESET}"
    command -v zsysctl >/dev/null 2>&1 && \
      out "    ${C_BOLD}sudo zsysctl state remove <state>${C_RESET}        ${C_DIM}# states created by zsys${C_RESET}"
    register_opp "${zfs_bytes:-0}" "REVIEW" "" \
      "${zfs_count} ZFS snapshot(s)" \
      "sudo zfs destroy <dataset>@<snap>  # loses the rollback to that point"
  fi
fi

# Timeshift — system backup; deleting a snapshot means losing a restore point
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
      register_opp "$ts_bytes" "REVIEW" "$ts_dir" "Timeshift snapshots" \
        "# list with 'sudo timeshift --list' and delete one at a time: sudo timeshift --delete --snapshot '<date>'"
    else
      note "  $ts_dir exists but isn't readable without sudo (run 'sudo timeshift --list')"
    fi
  done
fi

# Btrfs — listing subvolumes requires root; just point to the command
if [[ "$(df -PT / 2>/dev/null | awk 'NR==2 {print $2}')" == "btrfs" ]]; then
  snap_found=1
  note "  Root on Btrfs — list the snapshots with:"
  out "    ${C_BOLD}sudo btrfs subvolume list -s /${C_RESET}"
  out "    ${C_BOLD}sudo btrfs filesystem usage /${C_RESET}   ${C_DIM}# how much is really left${C_RESET}"
fi

[[ $snap_found -eq 1 ]] && note "  (Snapshots take up space without showing in the file manager)"
return 0

}

# --- Sandboxes / packaged apps ------------------------------------------------

containers_macos() {

section "~/Library/Containers — top $TOP_N"
run_spun "scanning ~/Library/Containers... (may take quite a while)" top_children_register "$HOME/Library/Containers" "$TOP_N" "REVIEW" "Container" '# clean it up from the app that owns {}'

}

containers_linux() {

# Flatpak and snap keep per-app data outside the XDG layout
flatpak_dir="$HOME/.var/app"
snap_dir="$HOME/snap"
[[ -d "$flatpak_dir" || -d "$snap_dir" ]] || return 0

section "Flatpak/Snap app data — top $TOP_N"
if [[ -d "$flatpak_dir" ]]; then
  note "~/.var/app (Flatpak):"
  run_spun "scanning ~/.var/app..." top_children_register "$flatpak_dir" "$TOP_N" "REVIEW" "Flatpak" '# app data; clean it up from the app itself or: flatpak uninstall <app>'
  out ""
fi
if [[ -d "$snap_dir" ]]; then
  note "~/snap (data per snap revision):"
  run_spun "scanning ~/snap..." top_children_register "$snap_dir" "$TOP_N" "REVIEW" "Snap (data)" '# snap data; goes away when you remove the snap: sudo snap remove <name>'
  out ""
  note "  Snap caches live in ~/snap/<app>/common/.cache — usually disposable."
fi

}

# --- System (Linux): packages, logs and crashes -------------------------------

section_linux_system() {

section "System — packages, logs and crashes"

# Package manager cache
case "$PKG" in
  apt)
    sys_report_dir /var/cache/apt/archives "SAFE" \
      "apt cache (downloaded .debs)" "sudo apt-get clean"
    sys_report_dir /var/lib/apt/lists "MODERATE" \
      "apt indexes (/var/lib/apt/lists)" \
      "sudo rm -rf /var/lib/apt/lists/*  # 'sudo apt update' downloads them again"
    ;;
  dnf)
    sys_report_dir /var/cache/dnf "SAFE" "dnf cache" "sudo dnf clean all" ;;
  pacman)
    sys_report_dir /var/cache/pacman/pkg "SAFE" "pacman cache" \
      "sudo paccache -rk1  # keeps the latest version of each package" ;;
esac

# Orphaned packages and old kernels: ask apt itself (the simulation runs
# without root). Adding up dpkg's linux-* overestimates: packages already removed
# with leftover config (rc) are still listed with their old size, and apt
# always keeps the running kernel and the previous one.
if [[ "$PKG" == apt ]] && command -v dpkg-query >/dev/null 2>&1; then
  autorm_pkgs=$(apt-get -s autoremove 2>/dev/null | awk '/^Remv / {print $2}')
  if [[ -n "$autorm_pkgs" ]]; then
    # shellcheck disable=SC2086  # package names have no spaces
    read -r autorm_count autorm_kb autorm_kern <<< "$(dpkg-query -W -f='${Package}\t${Installed-Size}\n' \
        $autorm_pkgs 2>/dev/null \
      | awk -F'\t' '{ n++; kb += $2 } $1 ~ /^linux-(image|modules|headers)-/ { k++ }
                    END { printf "%d %d %d\n", n+0, kb+0, k+0 }')"
    printf '  %8s  %s\n' "$(human_bytes $(( ${autorm_kb:-0} * 1024 )))" \
      "${autorm_count} orphaned package(s) in apt autoremove (${autorm_kern} from old kernels)"
    register_opp $(( ${autorm_kb:-0} * 1024 )) "SAFE" "" \
      "apt autoremove (${autorm_count} packages, ${autorm_kern} kernel)" \
      "sudo apt autoremove --purge  # keeps the running kernel and the previous one"
  fi

  # Biggest installed packages: /usr is usually the biggest block outside the home.
  # Only 'ii' ('rc' ones keep their old size); kernels are left out, the
  # autoremove above already handles the old ones. Informational: not ranked.
  pkg_top=$(dpkg-query -W -f='${db:Status-Abbrev}\t${Installed-Size}\t${Package}\n' 2>/dev/null \
    | awk -F'\t' '$1 == "ii " && $3 !~ /^linux-(image|modules|headers)-/ { print $2 "\t" $3 }' \
    | sort -rn | head -n 8)
  if [[ -n "$pkg_top" ]]; then
    note "  Biggest installed packages (for the ones you don't use: sudo apt remove <package>):"
    while IFS=$'\t' read -r kb name; do
      printf '  %8s    ↳ %s\n' "$(human_bytes $((kb * 1024)))" "$name"
    done <<< "$pkg_top"
  fi
fi

if command -v snap >/dev/null 2>&1; then
  # Installed snaps: each one is a whole .snap (squashfs) in
  # /var/lib/snapd/snaps, readable without root. Only goes away by removing the app.
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
      "${si_n} installed snap(s) — biggest: ${si_top%, }"
  fi

  # Disabled revisions stay on disk in full (a snap is a squashfs)
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
      "${snap_count} disabled snap revision(s)"
    # snap remove alone frees nothing: the revision's .snap stays in
    # snapd's download cache (now with no other link) until it is deleted
    register_opp $(( ${snap_kb:-0} * 1024 )) "SAFE" "" \
      "Disabled snap revisions (${snap_count})" \
      "snap list --all | awk '/disabled/{print \$1, \$3}' | while read -r n r; do sudo snap remove \"\$n\" --revision=\"\$r\"; done; sudo find /var/lib/snapd/cache -type f -links 1 -delete  # the removed .snap stays in snapd's cache"
    # snapd keeps refresh.retain revisions (default and minimum: 2, the current one + 1)
    snap_retain=$(snap get system refresh.retain 2>/dev/null || true)
    if [[ "$snap_retain" =~ ^[0-9]+$ && "$snap_retain" -gt 2 ]]; then
      note "  To keep fewer around: sudo snap set system refresh.retain=2 (currently: $snap_retain)"
      register_tip 0 "Snap keeps $snap_retain revisions of each app; 2 is enough" \
        "sudo snap set system refresh.retain=2  # the current one + one to roll back to"
    fi
  fi
  # The download cache is hardlinks to the installed .snaps: only a file
  # with no other link frees space (leftover of a removed revision). Without
  # root find can't enter the folder — say so instead of silently showing zero.
  if [[ -d /var/lib/snapd/cache && ! -r /var/lib/snapd/cache ]]; then
    printf '  %8s  %s  %s(downloads with no installed snap; root only)%s\n' "?" "/var/lib/snapd/cache" "$C_DIM" "$C_RESET"
  else
    snapc_kb=$(find /var/lib/snapd/cache -type f -links 1 -exec du -k {} + 2>/dev/null \
      | awk '{s+=$1} END {print s+0}')
    if [[ "${snapc_kb:-0}" -gt 0 ]]; then
      printf '  %8s  %s\n' "$(human_bytes $((snapc_kb * 1024)))" "/var/lib/snapd/cache (downloads with no installed snap)"
      register_opp $((snapc_kb * 1024)) "SAFE" "/var/lib/snapd/cache" "snapd download cache" \
        "sudo find /var/lib/snapd/cache -type f -links 1 -delete  # the rest are hardlinks of installed snaps"
    fi
  fi

  # Seed: the snaps that came with the install image. There is no official
  # command to clean it — informational only, not ranked.
  seed_kb=$(du -sk /var/lib/snapd/seed 2>/dev/null | awk '{print $1}')
  if [[ "${seed_kb:-0}" -ge 1024 ]]; then
    printf '  %8s  %s  %s(snaps from the install image; no official command to clean them)%s\n' \
      "$(human_bytes $((seed_kb * 1024)))" "/var/lib/snapd/seed" "$C_DIM" "$C_RESET"
  fi
fi

# Flatpak: orphaned runtimes after uninstalling apps
if command -v flatpak >/dev/null 2>&1; then
  sys_report_dir /var/lib/flatpak "MODERATE" "Flatpak (system apps + runtimes)" \
    "flatpak uninstall --unused  # removes runtimes no app uses"
fi

# systemd journal
if command -v journalctl >/dev/null 2>&1; then
  ju_line=$(journalctl --disk-usage 2>/dev/null | tail -1)
  ju_size=$(printf '%s' "$ju_line" | grep -oE '[0-9]+([.,][0-9]+)?[KMGT]i?B?' | tail -1)
  if [[ -n "${ju_size:-}" ]]; then
    ju_bytes=$(parse_size_to_bytes "${ju_size//,/.}")
    printf '  %8s  %s\n' "$(human_bytes "${ju_bytes:-0}")" "systemd journal (system logs)"
    register_opp "${ju_bytes:-0}" "SAFE" "" "systemd journal" \
      "sudo journalctl --vacuum-size=200M  # or --vacuum-time=7d"
    if grep -qsE '^[[:space:]]*SystemMaxUse=' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf; then
      note "  ✓ Max size configured (SystemMaxUse)"
    else
      note "  No limit configured. Permanent limit:"
      note "    sudo mkdir -p /etc/systemd/journald.conf.d"
      note "    printf '[Journal]\\\\nSystemMaxUse=500M\\\\n' | sudo tee /etc/systemd/journald.conf.d/size.conf"
      note "    sudo systemctl restart systemd-journald"
      register_tip 0 "systemd journal has no size limit: cap it at 500 MB" \
        "sudo mkdir -p /etc/systemd/journald.conf.d && printf '[Journal]\\nSystemMaxUse=500M\\n' | sudo tee /etc/systemd/journald.conf.d/size.conf >/dev/null && sudo systemctl restart systemd-journald"
    fi
  fi
fi

# /var/log outside the journal: total + huge files one by one. An app stuck in
# an error loop fills syslog in hours, and the rotated one (.1) is only
# compressed on the next rotation.
if [[ -d /var/log ]]; then
  vlog_kb=$(du -sk --exclude=journal /var/log 2>/dev/null | awk '{print $1}')
  vlog_bytes=$(( ${vlog_kb:-0} * 1024 ))
  if [[ $vlog_bytes -gt 0 ]]; then
    printf '  %8s  %s\n' "$(human_bytes "$vlog_bytes")" "/var/log (excluding the journal)"
    vlog_big=$(find /var/log -path /var/log/journal -prune -o -type f -size +100M -exec du -k {} + 2>/dev/null \
      | sort -rn | head -n "$TOP_N")
    while IFS=$'\t' read -r kb f; do
      [[ -n "$kb" && -n "$f" ]] || continue
      printf '  %8s    ↳ %s\n' "$(human_bytes $((kb * 1024)))" "$f"
      if [[ "$f" =~ \.[0-9]+(\.(gz|xz|zst))?$ || "$f" =~ -[0-9]{8}(\.(gz|xz|zst))?$ || "$f" =~ \.(gz|xz|zst|old)$ ]]; then
        register_opp $((kb * 1024)) "SAFE" "$f" "Rotated log: $(basename "$f")" \
          "sudo rm -f \"$f\"  # no longer in use"
      else
        register_opp $((kb * 1024)) "MODERATE" "$f" "Active log: $(basename "$f")" \
          "sudo truncate -s 0 \"$f\"  # and find out who is writing so much"
      fi
    done <<< "$vlog_big"
    if [[ -n "$vlog_big" ]]; then
      note "  Who filled it? sudo awk '{sub(/\\\\[.*/, \"\", \$3); print \$3}' <file> | sort | uniq -c | sort -rn | head"
    fi
  fi
fi

# Crashes: systemd core dumps and apport reports (Ubuntu)
sys_report_dir /var/lib/systemd/coredump "SAFE" "systemd core dumps" \
  "sudo rm -f /var/lib/systemd/coredump/*  # limit in /etc/systemd/coredump.conf"
sys_report_dir /var/crash "SAFE" "apport crash reports" \
  "sudo rm -f /var/crash/*"
sys_report_dir /var/tmp "MODERATE" "/var/tmp (temp files that survive a reboot)" \
  "# review first: sudo ls -lhS /var/tmp | head"

# Tools run with sudo leave caches in root's home (go build, pip...)
sys_report_dir /root/.cache "SAFE" "root's cache (/root/.cache)" \
  "sudo rm -rf /root/.cache/*  # regenerates"
sys_report_dir /root/go/pkg/mod "MODERATE" "root's Go modules (/root/go/pkg/mod)" \
  "sudo rm -rf /root/go/pkg/mod  # downloaded again on the next 'sudo go build'"

if [[ $EUID -ne 0 ]] && ! system_dirs_readable; then
  out ""
  note "  Some directories above are only readable as root — the numbers may be low."
fi

}

# --- Browsers -----------------------------------------------------------------

section_browsers_linux() {

# cache|profile|name|process|policy folder — only those present on the machine
# get listed. A process with '/' is matched against the command line (pgrep -f):
# the snap Chromium runs as "chrome", the same name as Google Chrome.
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
br_policy_dirs=""   # policy folders of the listed Chromium browsers
for br_entry in "${br_entries[@]}"; do
  IFS='|' read -r br_cache br_profile br_name br_proc br_policy <<< "$br_entry"
  [[ -d "$br_cache" || -d "$br_profile" ]] || continue
  br_lines=""   # only shows the browser if there is something to clean

  if [[ -d "$br_cache" ]]; then
    br_kb=$(run_spun "measuring ${br_name} cache..." du -sk "$br_cache" 2>/dev/null | awk '{print $1}')
    br_bytes=$(( ${br_kb:-0} * 1024 ))
    if [[ $br_bytes -gt 0 ]]; then
      br_lines+="$(printf '  %8s  %s' "$(human_bytes "$br_bytes")" "HTTP/code cache ($(tilde "$br_cache"))")"$'\n'
      register_opp "$br_bytes" "SAFE" "$br_cache" "${br_name}: HTTP/code cache" \
        "rm -rf \"$br_cache\"  # with the browser closed; regenerates as you browse"
    fi
  fi

  if [[ -d "$br_profile" && "$br_proc" != firefox ]]; then
    # With --user-data-dir outside ~/.config (the snap uses ~/snap/chromium/common)
    # Chromium writes the HTTP cache inside each profile, not in ~/.cache
    pc_kb=$(du -sk "$br_profile"/*/Cache "$br_profile"/*/"Code Cache" "$br_profile"/*/GPUCache 2>/dev/null \
      | awk '{s+=$1} END {print s+0}')
    pc_bytes=$(( ${pc_kb:-0} * 1024 ))
    if [[ $pc_bytes -gt 0 ]]; then
      br_lines+="$(printf '  %8s  %s' "$(human_bytes "$pc_bytes")" "HTTP/code cache inside the profiles (Cache, Code Cache, GPUCache)")"$'\n'
      # its own key path: with the whole profile's, the ranking dedup
      # would swallow the PWA line (or this one)
      register_opp "$pc_bytes" "SAFE" "$br_profile/*/Cache" "${br_name}: HTTP/code cache in profiles" \
        "rm -rf \"$br_profile\"/*/Cache \"$br_profile\"/*/\"Code Cache\" \"$br_profile\"/*/GPUCache  # browser closed; regenerates as you browse"
    fi

    # PWAs (Service Worker), across profiles
    sw_kb=$(du -sk "$br_profile"/*/"Service Worker/CacheStorage" 2>/dev/null | awk '{s+=$1} END {print s+0}')
    sw_bytes=$(( ${sw_kb:-0} * 1024 ))
    if [[ $sw_bytes -gt 0 ]]; then
      br_lines+="$(printf '  %8s  %s' "$(human_bytes "$sw_bytes")" "PWA offline cache (Service Worker, all profiles)")"$'\n'
      register_opp "$sw_bytes" "MODERATE" "$br_profile/*/Service Worker/CacheStorage" "${br_name}: PWA offline cache" \
        "rm -rf \"$br_profile\"/*/\"Service Worker/CacheStorage\"  # browser closed; PWAs re-download"
    fi
  fi

  [[ -n "$br_lines" ]] || continue
  if [[ $br_any -eq 0 ]]; then
    section "Browsers — manageable caches"
    br_any=1
  fi
  out "  ${C_BOLD}${br_name}${C_RESET}"
  printf '%s' "$br_lines"
  if [[ "$br_proc" == */* ]]; then br_pgrep=(pgrep -f "$br_proc"); else br_pgrep=(pgrep -x "$br_proc"); fi
  if "${br_pgrep[@]}" >/dev/null 2>&1; then
    note "  ⚠ ${br_name} is open — the rm commands above need the app closed."
  fi
  out ""
  [[ -n "$br_policy" ]] && br_policy_dirs+="$br_name|$br_policy"$'\n'
done

[[ $br_any -eq 1 ]] || return 0

# DiskCacheSize policy: Chromium then cleans up after itself instead of growing.
# Each browser reads its own folder — Chrome's doesn't apply to the snap Chromium.
while IFS='|' read -r br_name br_policy; do
  [[ -n "$br_policy" ]] || continue
  br_policy_file=$(grep -lsr DiskCacheSize "$br_policy" 2>/dev/null | head -1)
  if [[ -n "$br_policy_file" ]]; then
    out "  ${C_GREEN}✓ ${br_name} cache capped by policy${C_RESET} ${C_DIM}($br_policy_file)${C_RESET}"
  else
    out "  ${C_YELLOW}Tip:${C_RESET} cap the ${br_name} cache permanently (the browser then cleans up after itself):"
    out "    ${C_BOLD}sudo mkdir -p $br_policy${C_RESET}"
    out "    ${C_BOLD}echo '{\"DiskCacheSize\": 2147483648}' | sudo tee $br_policy/hogspot.json${C_RESET}  ${C_DIM}# 2 GB${C_RESET}"
    register_tip 0 "Cap the ${br_name} cache at 2 GB (it then cleans up after itself)" \
      "sudo mkdir -p $br_policy && echo '{\"DiskCacheSize\": 2147483648}' | sudo tee $br_policy/hogspot.json >/dev/null  # takes effect when the browser restarts"
  fi
done <<< "$br_policy_dirs"
note "  (Profiles, extensions, IndexedDB and Local Storage are site data — left out.)"

}

# --- Xcode / iOS (macOS) ------------------------------------------------------

# section_if body: without ~/Library/Developer, prints nothing
section_dev_xcode() {

if [[ -d "$HOME/Library/Developer" ]]; then
  for sub in Xcode/DerivedData Xcode/Archives Xcode/iOS\ DeviceSupport \
             Xcode/macOS\ DeviceSupport CoreSimulator/Devices \
             CoreSimulator/Caches XCTestDevices; do
    p="$HOME/Library/Developer/$sub"
    if [[ -e "$p" ]]; then
      bs=$(run_spun "measuring $sub..." du -sk "$p" 2>/dev/null | awk '{print $1*1024}')
      sz=$(human_bytes "${bs:-0}")
      printf "  %8s  %s\n" "$sz" "$p"

      # Command + risk level per subdir
      case "$sub" in
        Xcode/DerivedData)
          risk=SAFE;     cmd='rm -rf "$HOME/Library/Developer/Xcode/DerivedData"/*' ;;
        Xcode/Archives)
          risk=REVIEW;   cmd='# Xcode → Window → Organizer → delete old archives' ;;
        Xcode/iOS\ DeviceSupport|Xcode/macOS\ DeviceSupport)
          risk=MODERATE; cmd='# symbols regenerate when the device reconnects; old versions are fine to delete' ;;
        CoreSimulator/Devices)
          risk=REVIEW;   cmd='xcrun simctl delete unavailable  # or delete from Xcode → Devices' ;;
        CoreSimulator/Caches)
          risk=SAFE;     cmd='rm -rf "$HOME/Library/Developer/CoreSimulator/Caches"/*' ;;
        XCTestDevices)
          risk=MODERATE; cmd='xcrun simctl --set testing delete all  # ephemeral test simulators' ;;
        *)
          risk=REVIEW;   cmd="# review manually: $p" ;;
      esac
      register_opp "${bs:-0}" "$risk" "$p" "Xcode/$sub" "$cmd"
    fi
  done

  # Preview of 'simctl delete unavailable': lists simulators whose runtime
  # was removed (they just sit there taking up disk) and adds up their size.
  if command -v xcrun >/dev/null 2>&1 && xcrun simctl help >/dev/null 2>&1; then
    out ""
    unavail_list=$(run_spun "listing unavailable simulators..." xcrun simctl list devices unavailable 2>/dev/null)
    unavail_udids=$(printf '%s\n' "$unavail_list" \
      | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' || true)

    unavail_count=0
    unavail_bytes=0
    unavail_names=""
    if [[ -n "$unavail_udids" ]]; then
      # Measures all unavailable simulators in one go (single spinner).
      # Output per line: <bytes>|<human_size>|<name>
      unavail_data=$(run_spun "measuring unavailable simulators..." bash -c '
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
      out "  ${C_YELLOW}${unavail_count} unavailable simulator(s), $(human_bytes $unavail_bytes) total${C_RESET}"
      printf '%s' "$unavail_names"
      register_opp "$unavail_bytes" "SAFE" "$HOME/Library/Developer/CoreSimulator/Devices" "${unavail_count} unavailable iOS simulator(s)" "xcrun simctl delete unavailable"
    else
      out "  ${C_GREEN}Nothing to clean (no unavailable simulators).${C_RESET}"
    fi
  fi

  # --- Simulator runtimes (in /Library, outside the home) ---
  # iOS/iPadOS/watchOS/tvOS runtimes live in /Library and can be 6-8 GB each
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
    out "  ${C_BOLD}Simulator runtimes${C_RESET} ${C_DIM}(in /Library, outside the home):${C_RESET}"

    total_runtime_bytes=0
    for loc in "${runtime_locations[@]}"; do
      if [[ -d "$loc" ]]; then
        # Measures in KB with a spinner (a single call), then derives the human-readable size
        bs=$(run_spun "measuring $loc..." du -sk "$loc" 2>/dev/null | awk '{print $1*1024}')
        sz=$(human_bytes "${bs:-0}")
        total_runtime_bytes=$((total_runtime_bytes + ${bs:-0}))
        out "    $(printf '%8s' "$sz")  $loc"
        register_opp "${bs:-0}" "MODERATE" "$loc" "Simulator runtimes in $loc" "# Xcode → Settings → Platforms; or 'xcrun simctl runtime delete <id>'"
      fi
    done

    # Lists individual runtimes + extracts the identifiers of "unusable" ones to build the command
    if command -v xcrun >/dev/null 2>&1 && xcrun simctl help >/dev/null 2>&1; then
      runtime_list=$(run_spun "listing runtimes..." xcrun simctl runtime list 2>/dev/null)
      runtime_count=$(printf '%s\n' "$runtime_list" | grep -cE '^(iOS|iPadOS|watchOS|tvOS|visionOS) ' || true)

      # Extracts the identifiers (com.apple.CoreSimulator.SimRuntime.*) of lines marked unusable
      unusable_ids=$(printf '%s\n' "$runtime_list" \
        | awk '/[Uu]nusable/ {
            if (match($0, /com\.apple\.CoreSimulator\.SimRuntime\.[A-Za-z0-9._-]+/)) {
              print substr($0, RSTART, RLENGTH)
            }
          }')
      unusable_count=$(printf '%s\n' "$unusable_ids" | grep -c . || true)

      if [[ ${runtime_count:-0} -gt 0 ]]; then
        out ""
        out "    ${C_DIM}${runtime_count} installed runtime(s):${C_RESET}"
        printf '%s\n' "$runtime_list" | grep -E '^(iOS|iPadOS|watchOS|tvOS|visionOS) ' \
          | sed 's/^/      /'
      fi

      out ""
      if [[ ${unusable_count:-0} -gt 0 ]]; then
        out "    ${C_YELLOW}${unusable_count} runtime(s) marked 'unusable':${C_RESET}"
        while IFS= read -r id; do
          [[ -z "$id" ]] && continue
          out "      ${C_DIM}$id${C_RESET}"
        done <<< "$unusable_ids"
        out ""
        out "    ${C_GREEN}Delete them all at once:${C_RESET}"
        # Builds the real command with the identifiers (delete takes multiple args)
        ids_oneline=$(printf '%s ' $unusable_ids)
        out "      ${C_BOLD}xcrun simctl runtime delete ${ids_oneline}${C_RESET}"
      else
        out "    ${C_GREEN}No 'unusable' runtimes.${C_RESET}"
      fi

      out ""
      out "    ${C_DIM}Other ways to prune runtimes:${C_RESET}"
      out "      ${C_BOLD}xcrun simctl runtime list -v${C_RESET}                  ${C_DIM}# shows each one's identifier+state${C_RESET}"
      out "      ${C_BOLD}xcrun simctl runtime delete <id>${C_RESET}              ${C_DIM}# deletes 1 specific runtime${C_RESET}"
      out "      ${C_BOLD}xcrun simctl runtime delete --notUsedSinceDays 30${C_RESET}  ${C_DIM}# deletes those unused for 30+ days${C_RESET}"
      out "    ${C_DIM}Or from Xcode → Settings → Platforms${C_RESET}"
    fi
  fi

  out ""
  out "  ${C_GREEN}Safe commands (recap):${C_RESET}"
  out "    ${C_BOLD}rm -rf ~/Library/Developer/Xcode/DerivedData/*${C_RESET}"
  out "    ${C_BOLD}xcrun simctl delete unavailable${C_RESET}                       ${C_DIM}# simulators with no runtime${C_RESET}"
  out "    ${C_BOLD}xcrun simctl runtime delete --notUsedSinceDays 30${C_RESET}     ${C_DIM}# runtimes idle for 30+ days${C_RESET}"
fi

}

# section_if body: without backups, prints nothing
section_mobilesync() {

ms="$HOME/Library/Application Support/MobileSync/Backup"
if [[ -d "$ms" ]]; then
  ms_bytes=$(run_spun "measuring MobileSync backups... (can be tens of GB)" du -sk "$ms" 2>/dev/null | awk '{print $1*1024}')
  ms_size=$(human_bytes "${ms_bytes:-0}")
  out "  ${C_DIM}Total:${C_RESET} ${C_BOLD}${ms_size}${C_RESET}"
  out ""
  run_spun "listing individual backups..." top_children "$ms" 10
  note "Delete them from Finder → your device → Manage Backups."
  register_opp "${ms_bytes:-0}" "REVIEW" "$ms" "iPhone/iPad backups (MobileSync)" "# Finder → your device → Manage Backups"
fi

}

section_browsers_macos() {

CHROME_CACHE="$HOME/Library/Caches/Google/Chrome"
CHROME_AS="$HOME/Library/Application Support/Google/Chrome"
if [[ -d "$CHROME_CACHE" || -d "$CHROME_AS" ]]; then
  section "Google Chrome — manageable caches"

  chrome_running=0
  pgrep -qx "Google Chrome" 2>/dev/null && chrome_running=1

  if [[ -d "$CHROME_CACHE" ]]; then
    bs=$(run_spun "measuring Chrome HTTP cache..." du -sk "$CHROME_CACHE" 2>/dev/null | awk '{print $1*1024}')
    printf '  %8s  %s\n' "$(human_bytes "${bs:-0}")" "HTTP/code cache (~/Library/Caches/Google/Chrome)"
    register_opp "${bs:-0}" "SAFE" "$CHROME_CACHE" "Chrome: HTTP/code cache" \
      "rm -rf \"$CHROME_CACHE\"  # with Chrome closed; regenerates as you browse"
  fi

  if [[ -d "$CHROME_AS" ]]; then
    # PWA offline cache (Service Workers), added up across all profiles
    sw_kb=$(run_spun "measuring Chrome PWA caches..." \
      du -sk "$CHROME_AS"/*/"Service Worker/CacheStorage" 2>/dev/null \
      | awk '{s+=$1} END {print s+0}')
    sw_bytes=$(( ${sw_kb:-0} * 1024 ))
    if [[ $sw_bytes -gt 0 ]]; then
      printf '  %8s  %s\n' "$(human_bytes "$sw_bytes")" "PWA offline cache (Service Worker, all profiles)"
      register_opp "$sw_bytes" "MODERATE" "$CHROME_AS" "Chrome: PWA offline cache" \
        "rm -rf \"$CHROME_AS\"/*/\"Service Worker/CacheStorage\"  # Chrome closed; PWAs re-download"
    fi

    crx_kb=$(du -sk "$CHROME_AS/component_crx_cache" 2>/dev/null | awk '{print $1}')
    crx_bytes=$(( ${crx_kb:-0} * 1024 ))
    if [[ $crx_bytes -gt 0 ]]; then
      printf '  %8s  %s\n' "$(human_bytes "$crx_bytes")" "downloaded components (component_crx_cache)"
      register_opp "$crx_bytes" "SAFE" "$CHROME_AS/component_crx_cache" "Chrome: component_crx_cache" \
        "rm -rf \"$CHROME_AS/component_crx_cache\"  # Chrome closed; re-downloads on its own"
    fi
  fi

  out ""
  chrome_cap=$(defaults read com.google.Chrome DiskCacheSize 2>/dev/null || true)
  if [[ "$chrome_cap" =~ ^[0-9]+$ && "$chrome_cap" -gt 0 ]]; then
    out "  ${C_GREEN}✓ HTTP cache capped at $(human_bytes "$chrome_cap")${C_RESET} ${C_DIM}(DiskCacheSize policy — Chrome cleans up after itself)${C_RESET}"
  else
    out "  ${C_YELLOW}Tip:${C_RESET} cap the Chrome cache permanently (it then cleans up after itself):"
    out "    ${C_BOLD}defaults write com.google.Chrome DiskCacheSize -int 2147483648${C_RESET}  ${C_DIM}# 2 GB; takes effect after restarting Chrome${C_RESET}"
    register_tip 0 "Cap the Chrome cache at 2 GB (it then cleans up after itself)" \
      "defaults write com.google.Chrome DiskCacheSize -int 2147483648  # takes effect after restarting Chrome"
  fi
  if [[ $chrome_running -eq 1 ]]; then
    note "  ⚠ Chrome is open — the rm commands above need Chrome closed."
  fi
  note "  (Extensions, File System and IndexedDB are site/extension data, not cache — left out.)"
fi

}

# --- Homebrew -----------------------------------------------------------------

# section_if body: without brew, prints nothing
section_homebrew() {

if command -v brew >/dev/null 2>&1; then
  bc="$(brew --cache 2>/dev/null)"
  if [[ -n "$bc" && -d "$bc" ]]; then
    bc_kb=$(run_spun "measuring Homebrew cache..." du -sk "$bc" 2>/dev/null | awk '{print $1}')
    out "  Cache: ${C_BOLD}$(human_bytes $(( ${bc_kb:-0} * 1024 )))${C_RESET}  ${C_DIM}($bc)${C_RESET}"
  fi
  # Installed formulae (on Linux they live in /home/linuxbrew, outside $HOME)
  bp="$(brew --prefix 2>/dev/null)"
  if [[ -n "$bp" && -d "$bp/Cellar" ]]; then
    cellar_kb=$(run_spun "measuring Homebrew Cellar..." du -sk "$bp/Cellar" 2>/dev/null | awk '{print $1}')
    out "  Installed: ${C_BOLD}$(human_bytes $(( ${cellar_kb:-0} * 1024 )))${C_RESET}  ${C_DIM}($bp/Cellar)${C_RESET}"
    brew_orphans=$(brew autoremove -n 2>/dev/null | grep -oE 'Would autoremove [0-9]+' | grep -oE '[0-9]+$')
    if [[ "${brew_orphans:-0}" -gt 0 ]]; then
      out "  ${C_YELLOW}Orphaned dependencies (${brew_orphans}):${C_RESET} ${C_BOLD}brew autoremove${C_RESET}"
      register_tip 0 "Homebrew: orphaned dependencies installed (${brew_orphans})" \
        "brew autoremove  # removes what no installed formula uses"
    fi
  fi
  out ""

  # Dry-run with the SAME flags as the real command (-s and --prune=all),
  # otherwise the estimate is misleading (the default cleanup only removes >120 days).
  #
  # Conservative → 'brew cleanup -n'              (only >120 days)
  # Aggressive   → 'brew cleanup -ns --prune=all' (everything, including the current version in the cache)
  brew_default=$(run_spun "brew cleanup -n (default, >120 days)..." brew cleanup -n 2>&1)
  brew_full=$(run_spun "brew cleanup -ns --prune=all (aggressive)..." brew cleanup -ns --prune=all 2>&1)

  brew_default_pot=$(printf '%s\n' "$brew_default" | grep -iE 'approximately|would free' | tail -1)
  brew_full_pot=$(printf '%s\n' "$brew_full"    | grep -iE 'approximately|would free' | tail -1)
  brew_full_count=$(printf '%s\n' "$brew_full"  | grep -c -E '^Would remove' || true)

  if [[ -z "$brew_default_pot" && -z "$brew_full_pot" ]]; then
    out "  ${C_GREEN}Nothing to clean${C_RESET} ${C_DIM}(not even the aggressive brew cleanup finds anything to remove)${C_RESET}"
    return 0
  fi

  out "  ${C_DIM}Conservative mode (brew cleanup):${C_RESET}"
  if [[ -n "$brew_default_pot" ]]; then
    out "    ${brew_default_pot}"
  else
    out "    ${C_GREEN}Nothing to clean.${C_RESET}"
  fi
  out ""
  out "  ${C_BOLD}Aggressive mode (brew cleanup -s --prune=all):${C_RESET}"
  if [[ -n "$brew_full_pot" ]]; then
    out "    ${C_YELLOW}${brew_full_pot}${C_RESET}"
    if [[ ${brew_full_count:-0} -gt 0 ]]; then
      out "    ${C_DIM}(${brew_full_count} item(s) would be removed)${C_RESET}"
    fi
    # Registers it as an opportunity by extracting the size ("approximately 7.3GB")
    brew_size_str=$(echo "$brew_full_pot" | grep -oE '[0-9.]+[[:space:]]*[KMGT]?B' | head -1 | tr -d ' ')
    if [[ -n "$brew_size_str" ]]; then
      brew_bytes=$(parse_size_to_bytes "$brew_size_str")
      # path = brew cache: dedups with the same folder seen in the caches section
      register_opp "${brew_bytes:-0}" "SAFE" "${bc:-}" "Homebrew (cleanup -s --prune=all)" "brew cleanup -s --prune=all"
    fi
  else
    out "    ${C_GREEN}Nothing to clean.${C_RESET}"
  fi

  out ""
  out "  ${C_GREEN}To actually clean up (pick one):${C_RESET}"
  out "    ${C_BOLD}brew cleanup${C_RESET}                      ${C_DIM}# conservative${C_RESET}"
  out "    ${C_BOLD}brew cleanup -s --prune=all${C_RESET}       ${C_DIM}# aggressive, frees a lot more${C_RESET}"
fi

}

# --- Docker / OrbStack / Colima / Podman --------------------------------------

# section_if body: with no container runtime at all, prints nothing
section_containers() {

# Detects installed runtimes (even if they aren't running)
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

# On Linux the daemon may be running while the user has no permission on the socket
docker_no_perm=0
if [[ $OS == linux && $docker_running -eq 0 ]] \
   && command -v docker >/dev/null 2>&1 && [[ -S /var/run/docker.sock ]]; then
  docker_no_perm=1
fi

if [[ $docker_running -eq 1 ]]; then
  out "  ${C_DIM}docker system df:${C_RESET}"
  docker system df 2>/dev/null | sed 's/^/    /'
  out ""
  # The table's RECLAIMABLE column is what prune would free
  docker_total_bytes=$(container_df_bytes docker Reclaimable)
  register_opp "${docker_total_bytes:-0}" "REVIEW" "" "Docker (reclaimable images/containers/volumes)" "docker system prune -a --volumes  # CAREFUL: deletes unattached volumes"
  out "  ${C_GREEN}To clean unused images, networks and build cache:${C_RESET}"
  out "    ${C_BOLD}docker system prune -a --volumes${C_RESET}   ${C_RED}# careful: deletes unattached volumes${C_RESET}"
elif [[ $has_orbstack -eq 1 ]]; then
  out "  ${C_YELLOW}⚠ OrbStack is installed but not running.${C_RESET}"
  out "  ${C_DIM}Containers/images/volumes may be taking up a lot of space.${C_RESET}"
  out ""
  out "  To include this analysis:"
  out "    1. Start OrbStack: ${C_BOLD}open -a OrbStack${C_RESET}"
  out "    2. Wait for its menu bar icon to be ready"
  out "    3. Run ${C_BOLD}hogspot${C_RESET} again"
  register_blind "OrbStack stopped: containers, images and volumes weren't measured (open -a OrbStack and run again)"
elif [[ $has_docker_desktop -eq 1 ]]; then
  out "  ${C_YELLOW}⚠ Docker Desktop is installed but not running.${C_RESET}"
  out "  To include it: ${C_BOLD}open -a Docker${C_RESET}, wait for it to start and run hogspot again."
  register_blind "Docker Desktop stopped: images and volumes weren't measured (open -a Docker and run again)"
elif [[ $has_colima -eq 1 ]]; then
  out "  ${C_YELLOW}⚠ Colima is installed but not running.${C_RESET}"
  out "  To start it: ${C_BOLD}colima start${C_RESET}, then run hogspot again."
  register_blind "Colima stopped: images and volumes weren't measured (colima start and run again)"
elif [[ $docker_no_perm -eq 1 ]]; then
  out "  ${C_YELLOW}⚠ The Docker daemon is up, but your user has no access to its socket.${C_RESET}"
  out "  To include this analysis: ${C_BOLD}sudo usermod -aG docker \"$(id -un)\"${C_RESET} (log in again), or run with sudo."
  register_blind "Docker: your user can't access the socket, so what prune would free wasn't measured"
elif [[ $OS == linux && -d /var/lib/docker ]]; then
  out "  ${C_YELLOW}⚠ Docker is installed but the daemon isn't running.${C_RESET}"
  out "  To start it: ${C_BOLD}sudo systemctl start docker${C_RESET}, then run hogspot again."
  register_blind "Docker stopped: what prune would free wasn't measured (sudo systemctl start docker and run again)"
fi

# /var/lib/docker is where everything lives on Linux — measured even with the daemon stopped.
# On Docker 29+ images live in the containerd store (/var/lib/containerd).
# With the daemon up, the reclaimable above is already the freeable part and
# the on-disk size is just information (registering both would count twice).
if [[ $OS == linux ]]; then
  docker_risk="REVIEW"; [[ $docker_running -eq 1 ]] && docker_risk="-"
  podman_risk="REVIEW"; [[ $has_podman -eq 1 ]] && podman_risk="-"
  sys_report_dir /var/lib/docker "$docker_risk" "Docker (/var/lib/docker: images, volumes, build cache)" \
    "docker system prune -a --volumes  # CAREFUL: deletes unattached volumes"
  sys_report_dir /var/lib/containerd "$docker_risk" "containerd (/var/lib/containerd: Docker 29+ images)" \
    "docker image prune -a  # with the daemon running"
  sys_report_dir /var/lib/containers "$podman_risk" "Podman (/var/lib/containers)" \
    "podman system prune -a --volumes"
fi

# Podman runs without a daemon: it can be queried directly
if [[ $has_podman -eq 1 ]]; then
  out ""
  out "  ${C_DIM}podman system df:${C_RESET}"
  podman system df 2>/dev/null | sed 's/^/    /'
  podman_bytes=$(container_df_bytes podman Reclaimable)
  register_opp "${podman_bytes:-0}" "REVIEW" "" "Podman (reclaimable images/containers/volumes)" \
    "podman system prune -a --volumes"
  out "  ${C_GREEN}To clean up:${C_RESET} ${C_BOLD}podman system prune -a --volumes${C_RESET}"
fi

}

# =============================================================================
# REPORT
# =============================================================================

GENERATED_AT=$(date '+%Y-%m-%d %H:%M:%S')

print_header() {
  out "${C_BOLD}╭──────────────────────────────────────────────────────────╮${C_RESET}"
  out "${C_BOLD}│  hogspot — spot the disk hogs                            │${C_RESET}"
  out "${C_BOLD}╰──────────────────────────────────────────────────────────╯${C_RESET}"
  out "${C_DIM}Generated at $GENERATED_AT${C_RESET}"
  out "${C_DIM}System: $(os_label)${C_RESET}"
}

# Scans everything and prints the full report, section by section. Every
# freeable finding goes to $OPPS_FILE; the summary at the end comes from there.
full_report() {

if [[ $OS == macos ]] && ! has_full_disk_access; then
  out ""
  out "${C_YELLOW}⚠ Terminal has no Full Disk Access — areas like Mail/Messages/Safari won't be"
  out "  counted and the report may come out low. Enable it in: System Settings →"
  out "  Privacy & Security → Full Disk Access → your terminal.${C_RESET}"
  register_blind "No Full Disk Access: Mail, Messages and Safari were left out (System Settings → Privacy & Security → Full Disk Access)"
elif [[ $OS == linux && $EUID -ne 0 ]] && ! system_dirs_readable; then
  out ""
  out "${C_YELLOW}⚠ No root — system areas (/var/lib/docker, journal, /var/crash) aren't"
  out "  readable and the report may come out low. To count everything (still read-only):"
  out "    ${C_BOLD}sudo HOME=\"$HOME\" $0${C_RESET}${C_YELLOW}${C_RESET}"
fi

# --- Disk overview ---
section "Main disk overview"
if [[ $OS == macos ]]; then
  disk_overview_macos
else
  disk_overview_linux
  root_map_linux
fi

# --- Local snapshots ---
if [[ $OS == macos ]]; then
  section_if "Local Time Machine snapshots" snapshots_macos
else
  section_if "Local snapshots (ZFS / Timeshift / Btrfs)" snapshots_linux
fi

# --- Top-level folders of the home ---
section "Top $TOP_N folders in \$HOME"
run_spun "scanning \$HOME..." top_children "$HOME" "$TOP_N"

# --- Downloads ---
dl_label=$(tilde "$DOWNLOADS_DIR")
section "Downloads — big files (>100 MB)"
if [[ -d "$DOWNLOADS_DIR" ]]; then
  dl_bytes=$(run_spun "measuring $dl_label..." du -sk "$DOWNLOADS_DIR" 2>/dev/null | awk '{print $1*1024}')
  dl_total=$(human_bytes "${dl_bytes:-0}")
  out "  ${C_DIM}Folder total ($dl_label):${C_RESET} ${C_BOLD}${dl_total}${C_RESET}"
  out ""
  run_spun "looking for files >100MB in $dl_label..." big_files "$DOWNLOADS_DIR" 100 3 "$TOP_N"
  if same_fs "$DOWNLOADS_DIR" "$HOME"; then
    register_opp "${dl_bytes:-0}" "REVIEW" "$DOWNLOADS_DIR" "$dl_label (review big files)" \
      "# see the biggest ones with: ls -lhS \"$DOWNLOADS_DIR\" | head"
  else
    dl_mount=$(df -P "$DOWNLOADS_DIR" 2>/dev/null | awk 'NR==2 {print $NF}')
    out ""
    note "  It lives on another filesystem ($dl_mount) —"
    note "  deleting here frees no space on the home disk; left out of the summary."
    register_blind "$dl_label ($(human_bytes "${dl_bytes:-0}")) is on another disk ($dl_mount): cleaning it frees no space here"
  fi
fi

# --- Trash (only shows up with something inside) ---
status "Trash"
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
  section "Trash"
  printf '%s' "$trash_lines"
  note "Empty it from the file manager or: $trash_cmd"
fi
register_opp "$trash_total_bytes" "SAFE" "${trash_main:-$HOME/.Trash}" "Trash (all volumes)" "$trash_cmd"

# --- User caches ---
cache_label=$(tilde "$CACHE_DIR")
section "$cache_label — top $TOP_N"
run_spun "scanning $cache_label..." top_children_register "$CACHE_DIR" "$TOP_N" "SAFE" "Cache" 'rm -rf "{}"'
out ""
note "Deleting things in $cache_label is usually safe — apps regenerate them."
note "Exceptions are marked with their risk next to them (cloned git repositories$([[ $OS == macos ]] && printf ', iCloud/system'))."
note "Items with their own cleanup command (pip, uv, go, Homebrew...) show it in the summary."

# --- App data (Application Support / ~/.local/share) ---
appdata_label=$(tilde "$APPDATA_DIR")
if [[ $OS == macos ]]; then
  appdata_tag="Application Support"
  appdata_cmd='# review from the app: {}'
else
  appdata_tag="App data"
  appdata_cmd='# app data (not cache) — review first: {}'
fi
section "$appdata_label — top $TOP_N"
run_spun "scanning $appdata_label... (may take a while)" top_children_register "$APPDATA_DIR" "$TOP_N" "REVIEW" "$appdata_tag" "$appdata_cmd"

# --- Sandboxes / packaged apps ---
if [[ $OS == macos ]]; then
  containers_macos
else
  containers_linux
fi

# --- Logs (on Linux they are in the "System" section, next to the journal) ---
if [[ $OS == macos ]]; then
  section "~/Library/Logs — top 10"
  run_spun "scanning ~/Library/Logs..." top_children "$HOME/Library/Logs" 10
fi

# --- Xcode / iOS (macOS) ---
if [[ $OS == macos ]]; then
  section_if "~/Library/Developer (Xcode, simulators)" section_dev_xcode
  section_if "iPhone/iPad backups (MobileSync)" section_mobilesync
fi

# --- System: packages, logs and crashes (Linux) ---
if [[ $OS == linux ]]; then
  section_linux_system
fi

# --- Scattered dev caches ---
section "Dev tool caches (top level of \$HOME)"
# format: dir|risk|command
declare -a dev_dirs=(
  '.npm|SAFE|npm cache clean --force'
  '.pnpm-store|SAFE|pnpm store prune'
  '.yarn/cache|SAFE|yarn cache clean'
  '.cargo|REVIEW|# holds binaries installed in ~/.cargo/bin; do not delete it whole'
  '.gradle|MODERATE|rm -rf "$HOME/.gradle/caches"  # a rebuild downloads them again'
  '.m2/repository|MODERATE|rm -rf "$HOME/.m2/repository"  # deps download again on the next build'
  '.ivy2|MODERATE|# ivy/sbt deps; download again on the next build'
  '.sbt|MODERATE|# sbt caches; regenerate on the next build'
  '.pyenv|REVIEW|# installed Python versions; deleting breaks virtualenvs'
  '.rbenv|REVIEW|# installed Ruby versions'
  '.nvm|MODERATE|# in your shell (nvm is a function, not a binary): nvm cache clear; nvm uninstall <old-version>'
  '.rustup|MODERATE|rustup toolchain uninstall <old>  # list them with: rustup toolchain list'
  '.bun/install/cache|SAFE|bun pm cache rm'
  'go/pkg/mod|MODERATE|go clean -modcache'
  '.minikube|MODERATE|minikube delete --all'
  '.vagrant.d|MODERATE|vagrant box prune'
  '.docker|REVIEW|# Docker config/state; use docker system prune instead of deleting it'
)
if [[ $OS == macos ]]; then
  dev_dirs+=(
    '.cache|MODERATE|# may hold big models/downloads (huggingface, uv, etc); review first'
    '.cocoapods|MODERATE|pod cache clean --all'
    'Library/pnpm|MODERATE|pnpm store prune'
    '.colima|REVIEW|# Colima VM disk (holds your images and volumes)'
    '.lima|REVIEW|# Lima VM disks'
    '.orbstack|REVIEW|# OrbStack data; clean it up with docker prune while it runs'
  )
else
  # On Linux ~/.cache is already the user caches section — not repeated here.
  dev_dirs+=(
    '.local/share/pnpm|MODERATE|pnpm store prune'
    '.local/share/virtualenvs|REVIEW|# pipenv virtualenvs; recreate them with pipenv install'
    '.local/share/containers|REVIEW|# Podman images/volumes: podman system prune -a'
    '.local/lib|REVIEW|# Python packages installed with pip --user'
    '.nv|SAFE|rm -rf "$HOME/.nv/ComputeCache"  # CUDA kernel cache; regenerates'
    '.conda|MODERATE|conda clean --all'
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
    continue  # the breakdown already registered more specific opportunities
  fi
  register_opp "${b:-0}" "$dev_risk" "$p" "Dev cache: ~/$d" "$dev_cmd"
done

# Claude Code: the native installer keeps each whole version (~300 MB) in
# versions/, and session transcripts only go away after cleanupPeriodDays
cc_versions="${XDG_DATA_HOME:-$HOME/.local/share}/claude/versions"
if [[ -d "$cc_versions" ]]; then
  cc_current=$(basename "$(readlink -f "$HOME/.local/bin/claude" 2>/dev/null)")
  # without the installer's link, the version in use is the most recent one
  if [[ -z "$cc_current" || ! -f "$cc_versions/$cc_current" ]]; then
    # shellcheck disable=SC2012  # version names (2.1.310) have no spaces
    cc_current=$(ls -t "$cc_versions" 2>/dev/null | head -1)
  fi
  # Without knowing which one is in use, suggest nothing (an empty ! -name would match all)
  cc_old_n=0
  [[ -n "$cc_current" ]] && \
    read -r cc_old_kb cc_old_n <<< "$(find "$cc_versions" -mindepth 1 -maxdepth 1 -type f ! -name "$cc_current" \
        -exec du -k {} + 2>/dev/null | awk '{ s += $1; n++ } END { print s+0, n+0 }')"
  if [[ ${cc_old_n:-0} -gt 0 ]]; then
    printf "  %8s  %s\n" "$(human_bytes $((cc_old_kb * 1024)))" \
      "$(tilde "$cc_versions") (${cc_old_n} old Claude Code version(s); in use: $cc_current)"
    cc_cmd="find \"$cc_versions\" -maxdepth 1 -type f ! -name \"$cc_current\" -delete  # keeps $cc_current, the one in use"
    shell_safe "$cc_current" || cc_cmd="# delete the old versions by hand: $cc_cmd"
    register_opp $((cc_old_kb * 1024)) "SAFE" "$cc_versions" "Claude Code: ${cc_old_n} old version(s)" "$cc_cmd"
  fi
fi
cc_projects="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
if [[ -d "$cc_projects" ]]; then
  cc_kb=$(du -sk "$cc_projects" 2>/dev/null | awk '{print $1}')
  if [[ ${cc_kb:-0} -gt 0 ]]; then
    printf "  %8s  %s\n" "$(human_bytes $((cc_kb * 1024)))" "$(tilde "$cc_projects") (Claude Code transcripts)"
    register_opp $((cc_kb * 1024)) "REVIEW" "$cc_projects" "Claude Code: session transcripts" \
      "# lower \"cleanupPeriodDays\" in ~/.claude/settings.json (default: 30 days); older sessions drop out of /resume"
  fi
fi

if [[ $DETAIL -eq 0 ]]; then
  out ""
  note "Run with --detail to see the breakdown and commands per subfolder."
fi

# --- Homebrew ---
section_if "Homebrew" section_homebrew

# --- Docker / OrbStack / Colima ---
section_if "Docker / containers" section_containers

# --- Browsers ---
if [[ $OS == macos ]]; then
  section_browsers_macos
else
  section_browsers_linux
fi

# --- Projects: node_modules, build artifacts and worktrees ---
if [[ $QUICK -eq 0 ]]; then
  section "Projects in \$HOME — node_modules, builds and worktrees"
  run_spun "scanning projects in \$HOME (may take 30s-2min)..." scan_projects
else
  register_blind "--quick: node_modules, builds, worktrees and files >1 GB across \$HOME weren't scanned"
fi

# --- Huge stray files in ~ ---
if [[ $QUICK -eq 0 ]]; then
  section "Huge stray files in \$HOME (>1 GB, depth ≤5)"
  run_spun "looking for files >1GB in \$HOME (may take a while)..." big_files_register "$HOME" 1024 5 "$TOP_N" "REVIEW" "Big file"
fi


}  # end of full_report

# =============================================================================
# SUMMARY
# =============================================================================

# Summary items in the order they appear (the number in the menu is index + 1).
# Grouped by risk — SAFE, MODERATE, REVIEW, TWEAK — and by size.
IT_BYTES=() IT_RISK=() IT_PATH=() IT_DESC=() IT_CMD=() IT_DONE=()
SUM_SAFE=0 SUM_MODERATE=0 SUM_REVIEW=0
SMALL_STATS=""   # "risk<TAB>count<TAB>bytes" of the items below MIN_SUMMARY_BYTES

build_items() {
  local kept g bytes risk path desc cmd
  [[ -s "$OPPS_FILE" ]] || return 0

  # Dedup by path containment: an item inside another registered item is
  # dropped (the ancestor already counts those bytes). Exception: if the descendant
  # covers >=90% of the ancestor, it replaces it — same space with more
  # specific advice (e.g. MobileSync/Backup inside Application Support).
  kept=$(LC_ALL=C sort -t$'\t' -k3,3 -k5,5 "$OPPS_FILE" | awk -F'\t' '
    function flush() { if (root_line != "") print root_line }
    BEGIN { root_path = ""; root_line = "" }
    {
      bytes = $1 + 0; path = $3
      if (path == "") { print; next }   # no path: goes straight through
      if (root_path != "" && (path == root_path || index(path, root_path "/") == 1)) {
        if (root_bytes > 0 && bytes >= 0.9 * root_bytes) root_line = $0
        next
      }
      flush()
      root_path = path; root_bytes = bytes; root_line = $0
    }
    END { flush() }
  ')

  read -r SUM_SAFE SUM_MODERATE SUM_REVIEW <<< "$(awk -F'\t' '
    { s[$2] += $1 }
    END { printf "%d %d %d\n", s["SAFE"]+0, s["MODERATE"]+0, s["REVIEW"]+0 }
  ' <<< "$kept")"

  # Biggest first, one line per description (in case the same item gets in
  # twice); the small ones become a statistic, the rest become items. \037 as
  # separator: read would collapse consecutive tabs, and the path may be empty.
  kept=$(sort -t$'\t' -k1,1nr <<< "$kept" | awk -F'\t' '!seen[$4]++')
  SMALL_STATS=$(awk -F'\t' -v min="$MIN_SUMMARY_BYTES" '
    $2 != "TWEAK" && $1 < min { n[$2]++; b[$2] += $1 }
    END { for (r in n) printf "%s\t%d\t%d\n", r, n[r], b[r] }
  ' <<< "$kept")
  while IFS=$'\037' read -r g bytes risk path desc cmd; do
    [[ -n "$risk" ]] || continue
    IT_BYTES+=("$bytes"); IT_RISK+=("$risk"); IT_PATH+=("$path")
    IT_DESC+=("$desc"); IT_CMD+=("$cmd"); IT_DONE+=(0)
  done < <(awk -F'\t' -v OFS=$'\037' -v min="$MIN_SUMMARY_BYTES" '
      $2 != "TWEAK" && $1 < min { next }
      { g = ($2 == "SAFE") ? 1 : ($2 == "MODERATE") ? 2 : ($2 == "REVIEW") ? 3 : 4
        print g, $1, $2, $3, $4, $5 }
    ' <<< "$kept" | sort -s -t$'\037' -k1,1n)
}

risk_color() {
  case "$1" in
    SAFE)     printf '%s' "$C_GREEN" ;;
    MODERATE) printf '%s' "$C_YELLOW" ;;
    REVIEW)   printf '%s' "$C_RED" ;;
    *)        printf '%s' "$C_CYAN" ;;
  esac
}

risk_meaning() {
  case "$1" in
    SAFE)     echo "regenerates on its own" ;;
    MODERATE) echo "costs a re-download or rebuild" ;;
    REVIEW)   echo "your call: may contain your data" ;;
    *)        echo "tweaks and extras; not counted in the totals above" ;;
  esac
}

risk_title() {
  case "$1" in
    TWEAK) echo "OTHER ACTIONS" ;;
    *)     echo "$1" ;;
  esac
}

# Disk where the items free space (on macOS, the Data volume of the APFS container)
main_fs_path() {
  if [[ $OS == macos && -d /System/Volumes/Data ]]; then
    echo /System/Volumes/Data
  else
    echo /
  fi
}

# fs_stats <path> → "size_kb used_kb free_kb" (APFS: used = size - free)
fs_stats() {
  df -Pk "$1" 2>/dev/null | awk -v mac="$([[ $OS == macos ]] && echo 1)" '
    NR == 2 { print $2, (mac ? $2 - $4 : $3), $4 }'
}

avail_kb() {
  df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# $HOME on a disk separate from the main one (dedicated /home): each item frees
# space on its own disk, and it can't all be added up into one "free after"
home_on_other_disk() {
  [[ $OS == linux ]] && ! same_fs "$HOME" /
}

# free_delta <label> <free_kb before> <path> — how much the disk gained
free_delta() {
  local after delta
  after=$(avail_kb "$3")
  delta=$(( (${after:-0} - ${2:-0}) * 1024 ))
  if [[ $delta -gt 0 ]]; then
    printf '  %sFree now (%s): %s (+%s)%s\n' "$C_BOLD" "$1" \
      "$(human_bytes $(( ${after:-0} * 1024 )))" "$(human_bytes "$delta")" "$C_RESET"
  else
    printf '  Free now (%s): %s %s(no change)%s\n' "$1" \
      "$(human_bytes $(( ${after:-0} * 1024 )))" "$C_DIM" "$C_RESET"
  fi
}

# disk_line <path> <label>
disk_line() {
  local size used avail pct denom
  read -r size used avail <<< "$(fs_stats "$1")"
  [[ "${size:-0}" -gt 0 ]] || return 0
  denom=$(( used + avail > 0 ? used + avail : 1 ))
  pct=$(( (used * 100 + denom - 1) / denom ))
  printf '  %s%s: %s of %s used (%d%%) — %s free%s\n' "$C_BOLD" "$2" \
    "$(human_bytes $((used * 1024)))" "$(human_bytes $((size * 1024)))" "$pct" \
    "$(human_bytes $((avail * 1024)))" "$C_RESET"
}

# Executable part of a suggested command (without the trailing comment)
CMD_SEP='  # '
cmd_code() {
  [[ "${1:0:1}" == "#" ]] && return 0
  printf '%s\n' "${1%%"$CMD_SEP"*}"
}

# The command's trailing comment — or the whole command, when it is just an instruction
cmd_note() {
  local c="$1"
  if [[ "${c:0:1}" == "#" ]]; then
    c="${c#\#}"
    printf '%s\n' "${c# }"
  elif [[ "$c" == *"$CMD_SEP"* ]]; then
    printf '%s\n' "${c#*"$CMD_SEP"}"
  fi
}

# Can the menu run this item? Not when the command is just an instruction, has
# a blank to fill in (<project>, <id>) or the path has a character that would
# turn into code inside the quotes.
item_runnable() {
  local code re='<[^<> ]+>'
  code=$(cmd_code "${IT_CMD[$1]}")
  [[ -n "$code" ]] || return 1
  [[ "$code" =~ $re ]] && return 1
  # shellcheck disable=SC2016  # literal $( and backtick: command substitution
  [[ "$code" == *'$('* || "$code" == *'`'* ]] && return 1
  [[ -z "${IT_PATH[$1]}" ]] || shell_safe "${IT_PATH[$1]}"
}

# Numbered list, by risk group. $1 = 1 shows each item's command
# (without the menu, it's the only way to get to it).
print_items() {
  local show_cmds="$1" risk i n=${#IT_DESC[@]} any small_n small_b total
  for risk in SAFE MODERATE REVIEW TWEAK; do
    any=0
    for ((i = 0; i < n; i++)); do [[ "${IT_RISK[$i]}" == "$risk" ]] && any=1 && break; done
    small_n=0 small_b=0
    read -r small_n small_b <<< "$(awk -F'\t' -v r="$risk" '$1 == r { print $2, $3 }' <<< "$SMALL_STATS")"
    [[ $any -eq 1 || ${small_n:-0} -gt 0 ]] || continue

    total=""
    case "$risk" in
      SAFE)     total=$SUM_SAFE ;;
      MODERATE) total=$SUM_MODERATE ;;
      REVIEW)   total=$SUM_REVIEW ;;
    esac
    out ""
    printf '  %s%s%s%s %s— %s%s' "$C_BOLD" "$(risk_color "$risk")" "$(risk_title "$risk")" "$C_RESET" \
      "$C_DIM" "$(risk_meaning "$risk")" "$C_RESET"
    [[ -n "$total" ]] && printf ' %s(%s in total)%s' "$C_DIM" "$(human_bytes "$total")" "$C_RESET"
    printf '\n'

    for ((i = 0; i < n; i++)); do
      [[ "${IT_RISK[$i]}" == "$risk" ]] || continue
      local size=""
      [[ ${IT_BYTES[$i]} -gt 0 ]] && size=$(human_bytes "${IT_BYTES[$i]}")
      printf '   %s%3d.%s %9s  %s' "$C_BOLD" $((i + 1)) "$C_RESET" "$size" "${IT_DESC[$i]}"
      if [[ ${IT_DONE[$i]} -eq 1 ]]; then
        printf '  %s✓ done%s' "$C_GREEN" "$C_RESET"
      elif [[ $show_cmds -eq 0 ]] && ! item_runnable "$i"; then
        printf '  %s(manual)%s' "$C_DIM" "$C_RESET"
      fi
      printf '\n'
      [[ $show_cmds -eq 1 ]] && printf '                 %s↳ %s%s\n' "$C_DIM" "${IT_CMD[$i]}" "$C_RESET"
    done
    [[ ${small_n:-0} -gt 0 ]] && printf '                 %s+%d item(s) smaller than %s (%s)%s\n' \
      "$C_DIM" "$small_n" "$(human_bytes "$MIN_SUMMARY_BYTES")" "$(human_bytes "$small_b")" "$C_RESET"
  done
  return 0
}

print_summary() {
  local show_cmds="$1" main same_fs=1 line
  main=$(main_fs_path)

  section "Summary"
  if [[ $OS == macos ]]; then
    disk_line "$main" "Disk (APFS container)"
  else
    disk_line / "Disk (/)"
    if home_on_other_disk; then
      disk_line "$HOME" "\$HOME ($(df -P "$HOME" 2>/dev/null | awk 'NR==2 {print $NF}'))"
      same_fs=0
    fi
  fi
  out ""

  if [[ $((SUM_SAFE + SUM_MODERATE + SUM_REVIEW)) -eq 0 ]]; then
    out "  ${C_GREEN}Nothing worth cleaning.${C_RESET}"
  else
    local acc risk sum label
    acc=$(avail_kb "$main")
    acc=$(( ${acc:-0} * 1024 ))
    if [[ $same_fs -eq 1 ]]; then
      printf '  %-16s %10s %14s\n' "You can free" "frees" "free after"
    else
      printf '  %s\n' "You can free"
    fi
    for risk in SAFE MODERATE REVIEW; do
      case "$risk" in
        SAFE)     sum=$SUM_SAFE;     label="  SAFE" ;;
        MODERATE) sum=$SUM_MODERATE; label="+ MODERATE" ;;
        REVIEW)   sum=$SUM_REVIEW;   label="+ REVIEW" ;;
      esac
      acc=$((acc + sum))
      printf '  %s%-16s%s %10s' "$(risk_color "$risk")" "$label" "$C_RESET" \
        "$( [[ $sum -gt 0 ]] && human_bytes "$sum" || echo "-")"
      [[ $same_fs -eq 1 ]] && printf ' %14s' "$(human_bytes "$acc")"
      printf '   %s%s%s\n' "$C_DIM" "$(risk_meaning "$risk")" "$C_RESET"
    done
    note "  (estimates: overlapping items count once)"
  fi

  if [[ ${#IT_DESC[@]} -gt 0 ]]; then
    section "What can be cleaned"
    print_items "$show_cmds" | sed '1{/^$/d;}'
  fi

  if [[ -s "$BLIND_FILE" ]]; then
    out ""
    out "  ${C_YELLOW}Not counted:${C_RESET}"
    while IFS= read -r line; do
      printf '    · %s\n' "$line"
    done < <(awk '!seen[$0]++' "$BLIND_FILE")
  fi
  return 0
}

# Full report + summary, without colors, in a markdown file
write_report() {
  {
    echo "# hogspot report — $GENERATED_AT"
    echo ""
    echo '```'
    { print_header; cat "$FULL_OUT"; print_summary 1; } | sed -E $'s/\x1b\\[[0-9;]*m//g'
    echo '```'
  } > "$1"
}

# =============================================================================
# MENU
# =============================================================================

# "1 3 5-7" or "1,3" → indexes (base 0), one per line; fails if anything is invalid
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

# confirm <question> [word] — without a word accepts y/yes; with one, only that word
confirm() {
  local ans
  if [[ -n "${2:-}" ]]; then
    printf '  %s Type %s%s%s to confirm: ' "$1" "$C_BOLD" "$2" "$C_RESET"
    read -r ans || return 1
    [[ "$ans" == "$2" ]]
  else
    printf '  %s [y/N] ' "$1"
    read -r ans || return 1
    case "$ans" in y|Y|yes|Yes|YES) return 0 ;; esac
    return 1
  fi
}

# Biggest items inside a directory (for an item's details)
inner_top() {
  du -sk "$1"/* "$1"/.[!.]* 2>/dev/null | sort -rn | head -5
}

# show_item <index> <1 = look inside the folder>
show_item() {
  local i="$1" code note path="${IT_PATH[$1]}" size="" kb p
  [[ ${IT_BYTES[$i]} -gt 0 ]] && size=$(human_bytes "${IT_BYTES[$i]}")
  code=$(cmd_code "${IT_CMD[$i]}")
  note=$(cmd_note "${IT_CMD[$i]}")
  out ""
  printf '  %s%d. %s%s  %s%s%s%s  %s\n' "$C_BOLD" $((i + 1)) "${IT_DESC[$i]}" "$C_RESET" \
    "$C_BOLD" "$(risk_color "${IT_RISK[$i]}")" "$(risk_title "${IT_RISK[$i]}")" "$C_RESET" "$size"
  printf '     %s%s%s\n' "$C_DIM" "$(risk_meaning "${IT_RISK[$i]}")" "$C_RESET"
  [[ -n "$path" ]] && printf '     where:    %s\n' "$(tilde "$path")"
  if item_runnable "$i"; then
    printf '     command:  %s%s%s\n' "$C_BOLD" "$code" "$C_RESET"
    [[ -n "$note" ]] && printf '     note:     %s\n' "$note"
  else
    [[ -n "$code" ]] && printf '     command:  %s\n' "$code"
    [[ -n "$note" ]] && printf '     how:      %s\n' "$note"
    printf '     %s(manual: hogspot does not run this one — follow the instruction above)%s\n' "$C_DIM" "$C_RESET"
  fi
  if [[ "$2" == 1 && -n "$path" && "$path" != *'*'* && -d "$path" && -r "$path" ]]; then
    local inner
    inner=$(run_spun "looking inside $(tilde "$path")..." inner_top "$path")
    if [[ -n "$inner" ]]; then
      printf '     biggest inside:\n'
      while IFS=$'\t' read -r kb p; do
        [[ -n "$kb" ]] && printf '     %9s  %s%s%s\n' "$(human_bytes $((kb * 1024)))" "$C_DIM" "$(basename "$p")" "$C_RESET"
      done <<< "$inner"
    fi
  fi
  return 0
}

# Runs the (already confirmed) items by index and shows how much the disk gained
run_items() {
  local i code rc main before before_home=0 label="disk"
  main=$(main_fs_path)
  [[ $OS == linux ]] && label="/"
  before=$(avail_kb "$main")
  home_on_other_disk && before_home=$(avail_kb "$HOME")
  for i in "$@"; do
    code=$(cmd_code "${IT_CMD[$i]}")
    out ""
    printf '  %s$ %s%s\n' "$C_BOLD" "$code" "$C_RESET"
    # Running as root via sudo, whatever doesn't ask for sudo runs as the owner
    # of the home — otherwise pip/npm/brew would clean (or create) root's stuff
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
      printf '  %s✗ %s — exited with code %d%s\n' "$C_RED" "${IT_DESC[$i]}" "$rc" "$C_RESET"
    fi
  done
  out ""
  free_delta "$label" "$before" "$main"
  home_on_other_disk && free_delta "\$HOME" "$before_home" "$HOME"
  return 0
}

# Shows the details of the chosen items and offers to run the ones that have a command
select_items() {
  local sel i count run=() bytes=0 review=0 prompt
  if ! sel=$(parse_selection "$1") || [[ -z "$sel" ]]; then
    printf '  %sNot a valid choice: "%s". Use numbers from the list (1 to %d), like 2 or 1 3 5-7.%s\n' \
      "$C_YELLOW" "$1" "${#IT_DESC[@]}" "$C_RESET"
    return 0
  fi
  count=$(printf '%s\n' "$sel" | grep -c .)
  for i in $sel; do
    show_item "$i" "$([[ $count -le 3 ]] && echo 1 || echo 0)"
    [[ ${IT_DONE[$i]} -eq 1 ]] && { note "     (already run in this session)"; continue; }
    item_runnable "$i" || continue
    run+=("$i")
    bytes=$((bytes + IT_BYTES[i]))
    [[ "${IT_RISK[$i]}" == REVIEW ]] && review=1
  done
  out ""
  if [[ ${#run[@]} -eq 0 ]]; then
    note "  Nothing here for hogspot to run."
    return 0
  fi
  prompt="Run ${#run[@]} command(s)"
  [[ $bytes -gt 0 ]] && prompt+=" (frees ~$(human_bytes "$bytes"))"
  if [[ $review -eq 1 ]]; then
    confirm "${C_RED}${prompt}? Includes a REVIEW item: what it deletes won't come back.${C_RESET}" "yes" || { note "  Nothing was run."; return 0; }
  else
    confirm "${prompt}?" || { note "  Nothing was run."; return 0; }
  fi
  run_items "${run[@]}"
}

# Every SAFE item hogspot knows how to run, in a single confirmation
run_all_safe() {
  local i n=${#IT_DESC[@]} run=() bytes=0
  out ""
  for ((i = 0; i < n; i++)); do
    [[ "${IT_RISK[$i]}" == SAFE && ${IT_DONE[$i]} -eq 0 ]] || continue
    item_runnable "$i" || continue
    run+=("$i")
    bytes=$((bytes + IT_BYTES[i]))
    printf '   %s%3d.%s %9s  %s\n' "$C_BOLD" $((i + 1)) "$C_RESET" "$(human_bytes "${IT_BYTES[$i]}")" "${IT_DESC[$i]}"
    printf '                 %s$ %s%s\n' "$C_DIM" "$(cmd_code "${IT_CMD[$i]}")" "$C_RESET"
  done
  if [[ ${#run[@]} -eq 0 ]]; then
    note "  No pending SAFE item that hogspot knows how to run."
    return 0
  fi
  out ""
  confirm "Run these ${#run[@]} command(s) (frees ~$(human_bytes "$bytes"))?" || { note "  Nothing was run."; return 0; }
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
  printf '  Save to [%s]: ' "$(tilde "$def")"
  read -r f || return 0
  f="${f:-$def}"
  [[ "$f" == \~/* ]] && f="$HOME/${f#\~/}"
  if write_report "$f" 2>/dev/null; then
    printf '  %s✓ Report saved to %s%s\n' "$C_GREEN" "$f" "$C_RESET"
  else
    printf '  %s✗ Could not write to %s%s\n' "$C_RED" "$f" "$C_RESET"
  fi
}

menu() {
  local line
  [[ ${#IT_DESC[@]} -gt 0 ]] || return 0
  out ""
  out "  Type numbers from the list (e.g. ${C_BOLD}2${C_RESET} or ${C_BOLD}1 3 5-7${C_RESET}) to see details and clean up."
  out "  ${C_BOLD}a${C_RESET} runs all SAFE · ${C_BOLD}l${C_RESET} shows the list · ${C_BOLD}r${C_RESET} full report · ${C_BOLD}s${C_RESET} saves to a file · ${C_BOLD}Enter${C_RESET} quits"
  out "  ${C_DIM}Nothing runs without your confirmation.${C_RESET}"
  while :; do
    printf '\n  %s›%s ' "$C_CYAN" "$C_RESET"
    read -r line || { out ""; return 0; }
    line=$(printf '%s' "$line" | awk '{$1 = $1; print}')   # trims spaces
    case "$line" in
      ""|q|Q|quit|exit) return 0 ;;
      a|A) run_all_safe ;;
      l|L) print_items 0 ;;
      r|R) view_full_report ;;
      s|S) save_report_prompt ;;
      *) select_items "$line" ;;
    esac
  done
}

# =============================================================================
# MAIN
# =============================================================================

print_header
if [[ $FULL -eq 1 ]]; then
  full_report | tee "$FULL_OUT"
else
  # Without a status line (no color or no TTY), say the wait is normal
  [[ $SHOW_STATUS -eq 0 && -t 2 ]] && printf '  scanning... (may take a few minutes)\n' >&2
  full_report > "$FULL_OUT"
fi
[[ $SHOW_STATUS -eq 1 ]] && printf '\r\033[K' >&2
SHOW_STATUS=0 STATUS_MSG=""

build_items
print_summary $((1 - MENU))
out ""
out "${C_GREEN}✓ Scan finished in ${SECONDS} s.${C_RESET}"

if [[ -n "$REPORT_FILE" ]]; then
  if write_report "$REPORT_FILE"; then
    out "${C_GREEN}Full report saved to: $REPORT_FILE${C_RESET}"
  else
    printf 'Could not write the report to %s\n' "$REPORT_FILE" >&2
  fi
fi

if [[ $MENU -eq 1 ]]; then
  menu
elif [[ $FULL -eq 0 && -z "$REPORT_FILE" ]]; then
  note "Tip: --full shows the report section by section; --report FILE saves everything."
fi
