# Shared helpers for the bats test suite.
# Resolves the repository root and the path to the bash scripts under test.

# Repository root = two levels up from this helper (tests/helpers -> repo root).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
export SCRIPTS_DIR="${REPO_ROOT}/scripts/bash"
export FIXTURES_DIR="${REPO_ROOT}/tests/fixtures"

# Hermetic credentials: a developer's real Figma token (FIGMA_PAT or a keychain
# FIGMA_PAT_COMMAND exported from their shell profile) must never leak into the
# suite — otherwise tests that expect introspection to FAIL for lack of a token
# would instead hit the real Figma API. CI has neither set; clear them locally
# too so the suite behaves identically everywhere. A test that needs a token
# sets it explicitly. Also drop any inherited FIGMA_CONFIG / FIGMA_API_BASE.
unset FIGMA_PAT FIGMA_PAT_COMMAND FIGMA_CONFIG FIGMA_API_BASE

# Create an isolated, non-git temporary workspace so that figma_repo_root()
# falls back to $PWD instead of resolving the extension's own git root.
make_temp_workspace() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/figma-test.XXXXXX")"
  # Generated/cached Figma artifacts live under .figma/cache/; pre-create it so
  # tests can stage a snapshot or rendered section without a separate mkdir.
  mkdir -p "$dir/.figma/cache"
  printf '%s' "$dir"
}

# Path of the rendered section for the feature the test is acting as — mirrors
# figma_section_path, which scopes renders per feature so a design-less feature
# cannot wipe a design one's. Falls back to "default" exactly as the helper does
# when nothing identifies a feature (the temp workspace is not a git repo).
section_path() { # $1 = phase (spec|plan|tasks)
  printf '%s' "${WORKSPACE}/.figma/cache/sections/${SPECIFY_FEATURE:-default}/${1}.md"
}

# Stage a fake rendered section, creating the per-feature directory the real
# renderer would have created.
stage_section() { # $1 = phase, $2 = content (default "stale")
  local p; p="$(section_path "$1")"
  mkdir -p "$(dirname "$p")"
  printf '%s\n' "${2:-stale}" > "$p"
}

# Fail when a '#' in printed shell guidance is not preceded by whitespace: such a
# line looks like a commented command but is not one, and breaks on paste.
refute_glued_comment() {
  local offender
  offender="$(printf '%s\n' "$1" | grep -nE '[^[:space:]]#' || true)"
  if [ -n "$offender" ]; then
    echo "line with a '#' glued to a command: $offender" >&2
    return 1
  fi
}
