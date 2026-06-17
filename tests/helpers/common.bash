# Shared helpers for the bats test suite.
# Resolves the repository root and the path to the bash scripts under test.

# Repository root = two levels up from this helper (tests/helpers -> repo root).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
export SCRIPTS_DIR="${REPO_ROOT}/scripts/bash"
export FIXTURES_DIR="${REPO_ROOT}/tests/fixtures"

# Create an isolated, non-git temporary workspace so that figma_repo_root()
# falls back to $PWD instead of resolving the extension's own git root.
make_temp_workspace() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/figma-test.XXXXXX")"
  printf '%s' "$dir"
}
