#!/usr/bin/env bats
# Tests for scripts/bash/figma-introspect.sh

load helpers/common

setup() {
  SCRIPT="${SCRIPTS_DIR}/figma-introspect.sh"
  WORKSPACE="$(make_temp_workspace)"
  cd "$WORKSPACE"
}

teardown() {
  cd "$REPO_ROOT"
  [ -n "$WORKSPACE" ] && rm -rf "$WORKSPACE"
}

# Install a curl stand-in that replays $FAKE_CURL_BODY for any request and
# reports HTTP 200, so introspection runs offline.
install_fake_curl() {
  mkdir -p "${WORKSPACE}/bin"
  cat > "${WORKSPACE}/bin/curl" <<'FAKE'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|-H|--max-time) shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$out" ]] && cat "${FAKE_CURL_BODY}" > "$out"
printf '200'
FAKE
  chmod +x "${WORKSPACE}/bin/curl"
  export PATH="${WORKSPACE}/bin:${PATH}"
}

@test "fails when no target id is given" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"one of --file"* ]]
}

@test "errors when --config points to a missing file" {
  run "$SCRIPT" --config "${WORKSPACE}/does-not-exist.json" --file abc123
  [ "$status" -eq 1 ]
  [[ "$output" == *"config not found"* ]]
}

@test "writes a snapshot for a file response larger than the argv limit" {
  install_fake_curl
  export FIGMA_PAT="figd_dummy"
  # 2 MiB payload: exceeds Linux's 128 KiB per-argument limit and macOS's
  # 1 MiB total argv budget, so passing it via --argjson would fail execve.
  jq -n '{
    name: "big-file",
    lastModified: "2026-01-01T00:00:00Z",
    version: "42",
    document: { children: [ { id: "0:1", name: "Page 1", type: "CANVAS",
      children: [ { id: "1:1", name: "Frame A", type: "FRAME" } ] } ] },
    components: {}, styles: {},
    blob: ("x" * 2097152)
  }' > "${WORKSPACE}/big.json"
  export FAKE_CURL_BODY="${WORKSPACE}/big.json"

  run "$SCRIPT" --file BIGFILEKEY
  [ "$status" -eq 0 ]
  [ -f "${WORKSPACE}/.figma/context-snapshot.json" ]
  run jq -r '.pages | length' "${WORKSPACE}/.figma/context-snapshot.json"
  [ "$output" = "1" ]
}

@test "rejects a non-numeric --depth before any network call" {
  run "$SCRIPT" --file abc123 --depth two
  [ "$status" -eq 1 ]
  [[ "$output" == *"--depth must be a positive integer"* ]]
}
