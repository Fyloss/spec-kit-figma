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
