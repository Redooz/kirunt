#!/usr/bin/env bash
# kirunt global installer.
#
# Installs the kirunt agent bundle so `kiro-cli chat --agent kirunt` works from
# ANY directory for the current user — no hardcoded per-user paths, no manual
# JSON editing. Idempotent: safe to re-run to upgrade an existing install.
#
# What it does:
#   1. Copies the bundle (hooks, scripts, skills) to $KIRUNT_HOME
#      (default: ~/.kiro/kirunt).
#   2. Installs the four agent configs into ~/.kiro/agents. The main
#      kirunt.json is derived from agents/kirunt.json (the single source of
#      truth for tools/prompt), rewriting only its hook/resource paths to
#      point at the install location. Hooks use the CLI V3 profile-scoped
#      array format.
#   3. Makes hooks and scripts executable.
#   4. Validates every installed config with `kiro-cli agent validate`.
#
# Requires: jq (used to derive the installed main agent config). Remote mode
# also requires curl and tar to fetch/extract the GitHub source archive.
#
# Usage:
#   ./install.sh                       # install to ~/.kiro/kirunt
#   KIRUNT_HOME=/opt/kirunt ./install.sh   # install elsewhere
#   ./install.sh --mcp-caller-mode kiro-default  # use Kiro's built-in default agent
#   ./install.sh --uninstall           # remove everything this installed
#
#   # one-liner (no checkout required)
#   curl -fsSL https://raw.githubusercontent.com/Redooz/kirunt/main/install/install.sh | bash
#
# Env:
#   KIRUNT_HOME     Install location for the bundle. Default: ~/.kiro/kirunt
#   KIRO_HOME       Kiro config dir. Default: ~/.kiro
#   KIRUNT_REPO     GitHub owner/repo for remote installs.
#                   Default: Redooz/kirunt. Set it to install from a fork.
#   KIRUNT_VERSION  Branch or tag to download for remote installs. Default: main
#   KIRUNT_MCP_CALLER_MODE  MCP delegation mode: worker or kiro-default.
#                   Default: the value already in config.json (worker).
#   KIRUNT_SHA256   Optional SHA-256 checksum for the downloaded archive
#   KIRUNT_ARCHIVE_URL  Optional full archive URL override (testing/mirrors)

set -euo pipefail

# ---- resolve locations -------------------------------------------------------

# Directory this script lives in = install; bundle root = its parent. When the
# script is piped from curl there is no source file path, so leave both empty
# and let the remote bootstrap branch handle it.
SCRIPT_DIR=""
BUNDLE_SRC=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  BUNDLE_SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

KIRO_HOME="${KIRO_HOME:-$HOME/.kiro}"
KIRUNT_HOME="${KIRUNT_HOME:-$KIRO_HOME/kirunt}"
AGENTS_DIR="$KIRO_HOME/agents"
KIRUNT_REPO_DEFAULT="Redooz/kirunt"
KIRUNT_REPO="${KIRUNT_REPO:-$KIRUNT_REPO_DEFAULT}"
KIRUNT_VERSION="${KIRUNT_VERSION:-main}"

# For the config, prefer a ~-relative path when KIRUNT_HOME is under $HOME so
# the installed config stays portable/readable; otherwise use the absolute path.
config_path_for() {
  # $1 = subpath under KIRUNT_HOME (e.g. "hooks/check-file-size")
  local sub="$1"
  case "$KIRUNT_HOME/" in
    "$HOME"/*) printf '~/%s/%s' "${KIRUNT_HOME#"$HOME"/}" "$sub" ;;
    *)         printf '%s/%s' "$KIRUNT_HOME" "$sub" ;;
  esac
}

# ---- options -----------------------------------------------------------------

MCP_CALLER_MODE="${KIRUNT_MCP_CALLER_MODE:-}"
UNINSTALL=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --uninstall)
      UNINSTALL=true
      shift
      ;;
    --mcp-caller-mode)
      MCP_CALLER_MODE="${2:-}"
      shift 2
      ;;
    --mcp-caller-mode=*)
      MCP_CALLER_MODE="${1#*=}"
      shift
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      echo "Usage: install.sh [--uninstall] [--mcp-caller-mode worker|kiro-default]" >&2
      exit 1
      ;;
  esac
done

validate_mcp_caller_mode() {
  case "$1" in
    worker|kiro-default) return 0 ;;
    *)
      echo "Error: invalid mcp_caller_mode '$1' (expected worker or kiro-default)" >&2
      return 1
      ;;
  esac
}

if [ -n "$MCP_CALLER_MODE" ]; then
  validate_mcp_caller_mode "$MCP_CALLER_MODE" || exit 1
fi

# Best-effort engine detection. The V3 engine can live inside a 2.x CLI, so
# prefer the configured engine over the version number. If the setting is
# absent, a 3.x+ CLI is V3 and everything older defaults to V2.
detect_kiro_engine() {
  local engine version major
  [ -n "$KIRO_CLI" ] || return 0

  engine="$("$KIRO_CLI" settings list 2>/dev/null | sed -n 's/^chat\.agentEngine[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  if [ -n "$engine" ]; then
    printf '%s' "$engine"
    return 0
  fi

  version="$("$KIRO_CLI" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
  major="${version%%.*}"
  case "$major" in
    ''|*[!0-9]*) : ;;
    3|[4-9])     printf 'v3' ;;
    *)           printf 'v2' ;;
  esac
}

# ---- uninstall ---------------------------------------------------------------

if [ "$UNINSTALL" = true ]; then
  echo "Uninstalling kirunt..."
  rm -f "$AGENTS_DIR/kirunt.json" \
        "$AGENTS_DIR/kirunt-bulk-reader.json" \
        "$AGENTS_DIR/kirunt-code-writer.json" \
        "$AGENTS_DIR/kirunt-mcp-caller.json"
  echo "  removed agent configs from $AGENTS_DIR"
  if [ -d "$KIRUNT_HOME" ]; then
    rm -rf "$KIRUNT_HOME"
    echo "  removed bundle at $KIRUNT_HOME"
  fi
  echo "Done. (Global skills under ~/.kiro/skills, if any, were left untouched.)"
  exit 0
fi

# ---- remote bootstrap --------------------------------------------------------

# When this script is piped from curl there is no checkout next to it. Download
# the requested GitHub archive, extract it to a temp dir, and run the real
# installer from there. Local checkouts skip this entirely.
bootstrap_from_github() {
  local repo version ref url tmp archive src rc actual expected

  repo="${KIRUNT_REPO:-}"
  version="${KIRUNT_VERSION:-main}"

  if [ -z "$repo" ]; then
    echo "Error: KIRUNT_REPO is set but empty." >&2
    echo "  Unset it to use the default ($KIRUNT_REPO_DEFAULT), or set it to OWNER/REPO." >&2
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required for a remote install." >&2
    return 1
  fi
  if ! command -v tar >/dev/null 2>&1; then
    echo "Error: tar is required for a remote install." >&2
    return 1
  fi

  case "$version" in
    refs/*)              ref="$version" ;;
    main|master|develop) ref="refs/heads/$version" ;;
    *)                   ref="refs/tags/$version" ;;
  esac

  url="${KIRUNT_ARCHIVE_URL:-https://github.com/$repo/archive/$ref.tar.gz}"
  tmp="$(mktemp -d)" || return 1
  trap 'rm -rf "$tmp"' EXIT
  archive="$tmp/kirunt.tar.gz"

  echo "Downloading kirunt ($version) from $url..."
  if ! curl -fsSL "$url" -o "$archive"; then
    echo "Error: download failed: $url" >&2
    return 1
  fi

  if [ -n "${KIRUNT_SHA256:-}" ]; then
    expected="$(printf '%s' "$KIRUNT_SHA256" | tr '[:upper:]' '[:lower:]')"
    if command -v sha256sum >/dev/null 2>&1; then
      actual="$(sha256sum "$archive" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
      actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    else
      echo "Error: KIRUNT_SHA256 was set but no sha256 tool was found." >&2
      return 1
    fi
    if [ "$actual" != "$expected" ]; then
      echo "Error: checksum mismatch for $url" >&2
      echo "  expected: $expected" >&2
      echo "  actual:   $actual" >&2
      return 1
    fi
  fi

  if ! tar -xzf "$archive" -C "$tmp"; then
    echo "Error: could not extract $url" >&2
    return 1
  fi

  src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [ -z "$src" ] || [ ! -f "$src/install/install.sh" ]; then
    echo "Error: downloaded archive does not contain install/install.sh" >&2
    return 1
  fi

  if KIRUNT_REMOTE_INSTALL=1 KIRUNT_REPO="$repo" KIRUNT_VERSION="$version" \
    KIRUNT_HOME="$KIRUNT_HOME" KIRO_HOME="$KIRO_HOME" \
    KIRUNT_MCP_CALLER_MODE="$MCP_CALLER_MODE" \
    bash "$src/install/install.sh" "$@"; then
    rc=0
  else
    rc=$?
  fi

  rm -rf "$tmp"
  trap - EXIT
  return "$rc"
}

if [ ! -d "$BUNDLE_SRC/hooks" ] || [ ! -d "$BUNDLE_SRC/scripts" ] || [ ! -d "$BUNDLE_SRC/skills" ]; then
  if bootstrap_from_github "$@"; then
    exit 0
  else
    exit $?
  fi
fi

# ---- preflight ---------------------------------------------------------------

if ! command -v kiro-cli >/dev/null 2>&1; then
  echo "Warning: kiro-cli not found on PATH — configs will be installed but not validated." >&2
  KIRO_CLI=""
else
  KIRO_CLI="kiro-cli"
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required (used to derive the main agent config) but was not found on PATH." >&2
  echo "Install it, then re-run this script:" >&2
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      echo "    brew install jq" >&2
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        echo "    sudo apt-get update && sudo apt-get install -y jq" >&2
      elif command -v dnf >/dev/null 2>&1; then
        echo "    sudo dnf install -y jq" >&2
      elif command -v yum >/dev/null 2>&1; then
        echo "    sudo yum install -y jq" >&2
      elif command -v pacman >/dev/null 2>&1; then
        echo "    sudo pacman -S jq" >&2
      elif command -v apk >/dev/null 2>&1; then
        echo "    sudo apk add jq" >&2
      else
        echo "    (use your distro's package manager to install jq)" >&2
      fi
      ;;
    *)
      echo "    See https://jqlang.org/download/ for install instructions." >&2
      ;;
  esac
  exit 1
fi

if [ ! -d "$BUNDLE_SRC/hooks" ] || [ ! -d "$BUNDLE_SRC/scripts" ] || [ ! -d "$BUNDLE_SRC/skills" ]; then
  echo "Error: expected bundle dirs (hooks/, scripts/, skills/) under $BUNDLE_SRC" >&2
  exit 1
fi

# ---- copy the bundle ---------------------------------------------------------

echo "Installing kirunt bundle -> $KIRUNT_HOME"
mkdir -p "$KIRUNT_HOME"
# Copy the runtime pieces the agent needs at run time. Skip install/ (this
# script) and evals/ (dev-only) to keep the installed footprint minimal.
for d in hooks scripts skills; do
  rm -rf "${KIRUNT_HOME:?}/$d"
  cp -R "$BUNDLE_SRC/$d" "$KIRUNT_HOME/$d"
done
[ -f "$BUNDLE_SRC/README.md" ] && cp "$BUNDLE_SRC/README.md" "$KIRUNT_HOME/README.md"
# Apache-2.0 §4: the installed bundle is a redistribution, so ship the license
# and the upstream-attribution notice alongside it.
for f in LICENSE NOTICE; do
  [ -f "$BUNDLE_SRC/$f" ] && cp "$BUNDLE_SRC/$f" "$KIRUNT_HOME/$f"
done

# config.json is required, unlike README.md — kirunt.sh falls back to
# hardcoded defaults if it's missing at *runtime*, but a missing
# config.json at *install* time means the source bundle itself is
# incomplete, so fail loudly here rather than installing a half-complete
# bundle silently.
if [ -f "$BUNDLE_SRC/config.json" ]; then
  cp "$BUNDLE_SRC/config.json" "$KIRUNT_HOME/config.json"
  echo "  installed config.json -> $KIRUNT_HOME/config.json"

  if [ -n "$MCP_CALLER_MODE" ]; then
    tmp_config="$KIRUNT_HOME/config.json.tmp.$$"
    if ! jq --arg mode "$MCP_CALLER_MODE" '.mcp_caller_mode = $mode' \
      "$KIRUNT_HOME/config.json" > "$tmp_config"; then
      rm -f "$tmp_config"
      echo "Error: could not update mcp_caller_mode in $KIRUNT_HOME/config.json" >&2
      exit 1
    fi
    mv "$tmp_config" "$KIRUNT_HOME/config.json"
    echo "  mcp_caller_mode -> $MCP_CALLER_MODE"
  else
    current_mode="$(jq -r '.mcp_caller_mode // "worker"' "$KIRUNT_HOME/config.json" 2>/dev/null || true)"
    if ! validate_mcp_caller_mode "$current_mode"; then
      echo "Error: invalid mcp_caller_mode in $BUNDLE_SRC/config.json" >&2
      exit 1
    fi
  fi
else
  echo "Error: expected $BUNDLE_SRC/config.json but it was not found" >&2
  exit 1
fi

# ---- make executables executable ---------------------------------------------

chmod +x "$KIRUNT_HOME/hooks/check-file-size" \
         "$KIRUNT_HOME/hooks/check-bash-read" \
         "$KIRUNT_HOME/scripts/bulk-read" \
         "$KIRUNT_HOME/scripts/code-write" \
         "$KIRUNT_HOME/scripts/mcp-call"
echo "  made hooks + scripts executable"

# ---- install agent configs ---------------------------------------------------

mkdir -p "$AGENTS_DIR"

# Worker agents have no hooks/resources and reference nothing by path — they
# resolve by --agent name globally, so copy them verbatim.
cp "$BUNDLE_SRC/agents/kirunt-bulk-reader.json" "$AGENTS_DIR/kirunt-bulk-reader.json"
cp "$BUNDLE_SRC/agents/kirunt-code-writer.json" "$AGENTS_DIR/kirunt-code-writer.json"
cp "$BUNDLE_SRC/agents/kirunt-mcp-caller.json" "$AGENTS_DIR/kirunt-mcp-caller.json"

# Main agent: derive the installed kirunt.json from the source config
# ($BUNDLE_SRC/agents/kirunt.json), which is the single source of truth for
# tools/prompt/description. Only the path-dependent fields (resources + hook
# commands) are rewritten to point at the install location, so adding a tool
# or editing the prompt requires touching just the source config.
HOOK_FILESIZE="$(config_path_for hooks/check-file-size)"
HOOK_BASHREAD="$(config_path_for hooks/check-bash-read)"
SKILL_GLOB="skill://$(config_path_for 'skills/*/SKILL.md')"

MAIN_SRC="$BUNDLE_SRC/agents/kirunt.json"
if [ ! -f "$MAIN_SRC" ]; then
  echo "Error: source agent config not found: $MAIN_SRC" >&2
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  jq \
    --arg skill "$SKILL_GLOB" \
    --arg filesize "$HOOK_FILESIZE" \
    --arg bashread "$HOOK_BASHREAD" \
    '.resources = [$skill]
     | .hooks = [
         {
           name: "check-file-size",
           trigger: "PreToolUse",
           matcher: "read",
           action: { type: "command", command: $filesize }
         },
         {
           name: "check-bash-read",
           trigger: "PreToolUse",
           matcher: "shell",
           action: { type: "command", command: $bashread }
         }
       ]' \
    "$MAIN_SRC" > "$AGENTS_DIR/kirunt.json"
else
  echo "Error: jq is required to install the main agent config but was not found on PATH." >&2
  exit 1
fi
echo "  installed agent configs -> $AGENTS_DIR"

# ---- validate ----------------------------------------------------------------

if [ -n "$KIRO_CLI" ]; then
  rc=0
  for cfg in kirunt.json kirunt-bulk-reader.json kirunt-code-writer.json kirunt-mcp-caller.json; do
    if "$KIRO_CLI" agent validate --path "$AGENTS_DIR/$cfg" >/dev/null 2>&1; then
      echo "  valid: $cfg"
    else
      echo "  INVALID: $cfg" >&2
      "$KIRO_CLI" agent validate --path "$AGENTS_DIR/$cfg" >&2 || true
      rc=1
    fi
  done
  if [ "$rc" -ne 0 ]; then
    echo "Error: one or more configs failed validation." >&2
    exit 1
  fi
fi

echo
echo "kirunt installed. Use it from any directory:"
echo "    kiro-cli chat --agent kirunt"
echo
echo "Optionally make it your default agent:"
echo "    kiro-cli agent set-default kirunt"
echo
if [ "${KIRUNT_REMOTE_INSTALL:-}" = "1" ]; then
  echo "To uninstall:"
  echo "    curl -fsSL https://raw.githubusercontent.com/${KIRUNT_REPO}/${KIRUNT_VERSION}/install/install.sh \\"
  echo "      | KIRUNT_REPO=${KIRUNT_REPO} bash -s -- --uninstall"
else
  echo "To uninstall:  $0 --uninstall"
fi
