<div align="center">

```
╭──────────────────────────────────────────────────────────╮
│  hogspot — spot the disk hogs                            │
╰──────────────────────────────────────────────────────────╯
```

### Spot the disk hogs.

**Find out where your disk space went — and what is safe to delete.**

[![macOS](https://img.shields.io/badge/macOS-supported-C97B5B?style=flat-square&logo=apple&logoColor=white)](#-requirements)
[![Linux](https://img.shields.io/badge/Linux-Ubuntu%20%2F%20Debian-C97B5B?style=flat-square&logo=linux&logoColor=white)](#-requirements)
[![Confirmation](https://img.shields.io/badge/cleanup-only%20after%20confirmation-7BA887?style=flat-square)](#-safety)
[![Bash](https://img.shields.io/badge/bash-3.2%2B-D8A155?style=flat-square&logo=gnubash&logoColor=white)](#-requirements)
[![Zero deps](https://img.shields.io/badge/dependencies-none-7BA887?style=flat-square)](#-requirements)
[![MIT License](https://img.shields.io/badge/license-MIT-D8A155?style=flat-square)](LICENSE)

</div>

---

`hogspot` is a single shell script that scans your machine, shows **where the space
is going** and — what nobody else does — **which command gets each GB back**,
labeled by risk.

The scan deletes nothing. At the end, a menu shows the details of each item and runs
the command you pick — only after you confirm.

> **Why it exists:** DaisyDisk shows you *where* it is. `du -sh *` shows you *how much*.
> Neither tells you that those 18 GB are orphaned iOS simulators that go away with
> a single `xcrun simctl delete unavailable`.

---

## ⚡ Quick start

```bash
git clone https://github.com/trentas/hogspot.git
cd hogspot
./hogspot.sh
```

No install, no daemon, no dependencies. If you want it on your `PATH`:

```bash
sudo install -m 755 hogspot.sh /usr/local/bin/hogspot
hogspot
```

It scans the machine, shows a summary of what can be cleaned and opens a menu: type
an item's number to see what it is, where it lives and the command that frees the space.

**In a hurry?** `./hogspot.sh --quick` skips the slow scans (projects and huge
files across `$HOME`) and finishes in seconds.

---

## 📋 Sample output

The summary starts with what matters — how much you can free and at what risk — and
lists every opportunity, numbered and grouped by risk level:

```text
━━ Summary ━━

  Disk (APFS container): 393.7 GB of 460.4 GB used (86%) — 66.7 GB free

  You can free          frees     free after
    SAFE              47.3 GB       114.0 GB   regenerates on its own
  + MODERATE          23.9 GB       137.9 GB   costs a re-download or rebuild
  + REVIEW            61.2 GB       199.1 GB   your call: may contain your data
  (estimates: overlapping items count once)

━━ What can be cleaned ━━

  SAFE — regenerates on its own (47.3 GB in total)
     1.   18.4 GB  7 unavailable iOS simulator(s)
     2.    7.3 GB  Homebrew (cleanup -s --prune=all)
     3.    6.8 GB  Cache: com.brave.Browser
     ...

  MODERATE — costs a re-download or rebuild (23.9 GB in total)
     9.   12.7 GB  Simulator runtimes in /Library/Developer/CoreSimulator/Profiles/Runtimes  (manual)
     ...

  REVIEW — your call: may contain your data (61.2 GB in total)
    14.    9.1 GB  Docker (reclaimable images/containers/volumes)
     ...

  Not counted:
    · --quick: node_modules, builds, worktrees and files >1 GB across $HOME weren't scanned

✓ Scan finished in 41 s.

  Type numbers from the list (e.g. 2 or 1 3 5-7) to see details and clean up.
  a runs all SAFE · l shows the list · r full report · s saves to a file · Enter quits
  Nothing runs without your confirmation.
```

<details>
<summary><b>Cleaning an item from the menu</b></summary>

```text
  › 2

  2. Homebrew (cleanup -s --prune=all)  SAFE  7.3 GB
     regenerates on its own
     where:    ~/Library/Caches/Homebrew
     command:  brew cleanup -s --prune=all
     biggest inside:
        6.9 GB  downloads
      412.0 MB  Cask

  Run 1 command(s) (frees ~7.3 GB)? [y/N] y

  $ brew cleanup -s --prune=all
  ==> This operation has freed approximately 7.3GB of disk space.
  ✓ Homebrew (cleanup -s --prune=all)

  Free now (disk): 74.0 GB (+7.3 GB)
```

</details>

Want the report section by section (every cache, the root map, `docker system df`,
the Homebrew dry-runs)? Run it with `--full`, or press `r` in the menu.

---

## 🎛 Options

| Flag | What it does |
|---|---|
| *(none)* | Summary of what can be cleaned, followed by the menu |
| `--full` | Prints the full report, section by section, before the summary |
| `--top N` | How many items per section in the full report (default: `15`) |
| `--quick` | Skips the slow scans (projects — `node_modules`, builds, worktrees — and huge files in `$HOME`) |
| `--detail` | Breaks down what's inside the dev caches, with a command per subfolder |
| `--report FILE` | Saves the full report (sections + summary with the commands) as markdown |
| `--no-menu` | Print only, no menu at the end (the summary then shows each item's command) |
| `--no-color` | No colors or spinner (good for pipes, CI and logs) |
| `--help`, `-h` | Help |

```bash
./hogspot.sh --detail --top 25
./hogspot.sh --report ~/Downloads/hogspot-$(date +%F).md
./hogspot.sh --quick --full --no-color > report.txt
```

---

## 🔍 What it looks at

Each section only shows up if it exists on your machine — no Docker installed, no Docker section.

| Area | macOS | Linux |
|---|---|---|
| **Disk overview** | APFS container + every volume (not just `/`) | `/`, `$HOME` and `/boot` separately; warns when `/boot` goes over 80%; swapfile and the ext4 reserve (with a `tune2fs` tip when the disk is tight) |
| **Root map** | — | `/` by folder (opening up `/home`, `/var`, `/var/lib` and `/opt`), reconciled with `df`: without root it shows what couldn't be measured (and what Docker reports); with root, it points to deleted files still held open (`lsof +L1`) |
| **Local snapshots** | Time Machine (`tmutil`) | ZFS / Timeshift / Btrfs |
| **Home** | Top N folders, Downloads, Trash | same (honors `xdg-user-dir`) |
| **User caches** | `~/Library/Caches` | `~/.cache` (`$XDG_CACHE_HOME`) |
| **App data** | `~/Library/Application Support` | `~/.local/share` |
| **Packaged apps** | `~/Library/Containers` | Flatpak (`~/.var/app`) and Snap (`~/snap`) |
| **System** | Logs in `~/Library/Logs` | apt/dnf/pacman cache, `apt autoremove` (orphans and old kernels, by apt itself), biggest installed packages, installed snaps, disabled revisions and orphaned snapd downloads, install seed, systemd journal (warns when it has no limit), huge `/var/log` files one by one, core dumps, apport, root's caches (`/root/.cache`, `/root/go`) |
| **Xcode / iOS** | DerivedData, Archives, DeviceSupport, unavailable simulators, `unusable` runtimes, MobileSync backups | — |
| **Browsers** | Chrome: HTTP cache, PWAs, `component_crx_cache` | Chrome, Chromium, Brave, Edge, Vivaldi, Firefox (incl. snap and Flatpak) |
| **Homebrew** | Conservative **and** aggressive dry-runs, with the real gain of each; Cellar size and orphaned dependencies | same, if installed |
| **Containers** | Docker, OrbStack, Colima, Lima | Docker (incl. `/var/lib/containerd`), Podman |
| **Dev caches** | `.npm`, `.pnpm-store`, `.yarn`, `.gradle`, `.m2`, `.cargo`, `.rustup`, `.nvm`, `.bun`, `go/pkg/mod`, `.cocoapods`, `.minikube`, `.vagrant.d`, Claude Code (old versions and transcripts)… | same + `.conda`, `.nv`, pipenv virtualenvs, `pip --user` packages |
| **Projects** | `node_modules` (aggregated total), build artifacts (`.next`, `.turbo`, Rust/Maven `target/`), git worktrees with age and local changes | same |
| **Strays** | Single files > 1 GB | same |

---

## 🚦 Risk levels

Every opportunity gets a label. It's the difference between "frees space" and "frees space and you regret it".

| Level | Means | Examples |
|---|---|---|
| 🟢 **SAFE** | Regenerates on its own. You lose nothing but a download. | DerivedData, npm cache, trash, simulators with no runtime, brew cache |
| 🟡 **MODERATE** | Can be freed, but costs a re-download or rebuild. | `~/.gradle/caches`, `~/.m2/repository`, `go clean -modcache`, Simulator runtimes |
| 🔴 **REVIEW** | Manual decision. May have your data inside. | `Application Support`, Xcode Archives, ZFS snapshots, iPhone backups, git worktrees, big stray files |

Some items get refined automatically: a `~/.cache/pip` doesn't become a generic `rm -rf`,
it becomes `pip cache purge`. iCloud caches (`com.apple.bird`, `CloudDocs`, `cloudd`) are
downgraded to **REVIEW** even though they live inside `Caches` — deleting them triggers a re-sync.
A cache folder full of git repositories (regular or `--bare` clones) becomes **MODERATE**:
no app recreates that on its own, only cloning again does.

The summary also **dedups by containment**: if a folder and one of its subfolders are
both registered, their bytes count once. No adding up to 400 GB on a 460 GB disk.
Items under 50 MB collapse into a single line per level ("+5 smaller items").

Besides the three levels, the summary has **Other actions** — tweaks that slow down
growth or give space back without deleting anything (capping the browser cache, the
journal size, the ext4 reserve), which stay out of the totals — and **Not counted**:
what the scan couldn't measure (no root, Docker stopped, `--quick`).

---

## 🛡 Safety

The contract is short:

- **The scan changes nothing.** It only calls `du`, `find`, `df` and the tools'
  official dry-runs (`brew cleanup -n`, `apt-get -s autoremove`,
  `docker system df`, `simctl list`, `git --no-optional-locks status`).
- **Nothing runs without your confirmation.** The menu shows the exact command before
  asking; the default answer is *no*. A **REVIEW** item only runs if you type `yes`.
- **What needs judgment stays with you.** Application Support, iPhone backups,
  project `node_modules` and any command with a blank (`<id>`, `<project>`) show up
  as *manual*: hogspot shows the instruction and runs nothing.
- **Suspicious paths don't become commands.** If a folder name has quotes, `$` or a
  backtick, the item can't be run from the menu — inside the quotes, that would become code.
- **Outside a terminal, it only prints.** In a pipe, in CI or with `--no-menu` there is no menu.
- **No network.** It downloads nothing, sends no telemetry, never asks for your email.
- **No daemon.** It runs, shows, exits.
- **2,500 lines of readable bash.** If you don't trust it, [read it](hogspot.sh).

---

## 🔑 Permissions

The script runs with no privileges at all — but then it sees less, and it tells you when that happens.

**macOS — Full Disk Access.** Without it, areas like Mail, Messages and Safari are
invisible and the total comes out low. Enable it in
*System Settings → Privacy & Security → Full Disk Access* → your terminal.

**Linux — root.** `/var/lib/docker`, the journal, `/var/crash`, the snapd cache and
`/root` aren't readable by your user. To count everything (the scan stays read-only):

```bash
sudo HOME="$HOME" ./hogspot.sh
```

When run this way, menu commands that don't start with `sudo` (`npm cache clean`,
`brew cleanup`, `rm` on caches in your home) run as your user, not as root.

---

## 📄 Markdown report

```bash
./hogspot.sh --report ~/Downloads/hogspot-$(date +%F).md
```

Saves the full report — every section plus the summary, with each item's command —
without color codes. Handy for comparing two scans, attaching to a ticket or keeping
before you sell your Mac. In the menu, `s` does the same.

---

## 💻 Requirements

|  | |
|---|---|
| **OS** | macOS (any recent version) or Linux — Ubuntu/Debian first, but Fedora and Arch are detected too |
| **Shell** | `bash` 3.2+ (the one that ships with macOS; no bash 5 required) |
| **Tools** | `du`, `find`, `df`, `awk`, `sort` — basic POSIX |
| **Optional** | `tmutil`, `sw_vers`, `xcrun`, `brew`, `docker`, `git`, `apt-get`, `dpkg`, `snap`, `flatpak`, `journalctl`, `swapon`, `zfs`, `timeshift` — each one is used only if present |

---

## 🤝 Contributing

Issues and PRs are welcome. Two things help a lot:

1. **A missing cache.** If you have a huge folder from some tool that `hogspot`
   ignores, open an issue with the path, the size and the official cleanup command.
   It's the kind of contribution that improves the script the most.
2. **Output from another distro.** Linux support started out focused on Ubuntu/Debian —
   reports from Fedora, Arch, openSUSE and friends are gold.

Before sending a PR: keep the scan **read-only** (only the menu runs things, and only
after confirmation), add no new dependencies and stay compatible with `bash` 3.2. Run `shellcheck`.
For messages, the tone is that of a colleague at the next desk: direct, no fake urgency
("your disk is critical!") and no exclamation marks on routine actions.

---

## 📜 License

[MIT](LICENSE). Use, modify and redistribute it freely. The script comes as is,
with no warranty: it shows the command before running it precisely so the call is yours.

---

<div align="center">
<sub>

**hogspot** — *hog* (the process/file that eats resources) + *spot* (to find).
Where the hogs hide. Never `HogSpot`.

</sub>
</div>
