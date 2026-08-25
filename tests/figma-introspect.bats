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
# reports HTTP 200, so introspection runs offline. Every invocation is appended
# to $FAKE_CURL_LOG so tests can assert on the requested URL.
install_fake_curl() {
  mkdir -p "${WORKSPACE}/bin"
  export FAKE_CURL_LOG="${WORKSPACE}/curl-args.log"
  cat > "${WORKSPACE}/bin/curl" <<'FAKE'
#!/usr/bin/env bash
[[ -n "${FAKE_CURL_LOG:-}" ]] && printf '%s\n' "$*" >> "$FAKE_CURL_LOG"
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
  [ -f "${WORKSPACE}/.figma/cache/context-snapshot.json" ]
  run jq -r '.pages | length' "${WORKSPACE}/.figma/cache/context-snapshot.json"
  [ "$output" = "1" ]
}

@test "rejects a non-numeric --depth before any network call" {
  run "$SCRIPT" --file abc123 --depth two
  [ "$status" -eq 1 ]
  [[ "$output" == *"--depth must be a positive integer"* ]]
}

@test "accepts a URL-form --node and queries the canonical id" {
  install_fake_curl
  export FIGMA_PAT="figd_dummy"
  jq -n '{name:"f", lastModified:"2026-01-01T00:00:00Z", version:"1",
    document:{children:[]}, components:{}, styles:{},
    nodes:{"12:345":{document:{id:"12:345"}}}}' > "${WORKSPACE}/node.json"
  export FAKE_CURL_BODY="${WORKSPACE}/node.json"

  # An agent that copies the id straight out of the deep link passes '12-345';
  # the API only knows '12:345' and would answer "node not found".
  run "$SCRIPT" --file abc123 --node 12-345
  [ "$status" -eq 0 ]
  run grep -c 'nodes?ids=12:345' "${FAKE_CURL_LOG}"
  [ "$output" -ge 1 ]
}

@test "percent-encodes the ';' of a nested-instance --node in the query" {
  install_fake_curl
  export FIGMA_PAT="figd_dummy"
  jq -n '{name:"f", lastModified:"2026-01-01T00:00:00Z", version:"1",
    document:{children:[]}, components:{}, styles:{},
    nodes:{"I12:345;678:901":{document:{id:"I12:345;678:901"}}}}' > "${WORKSPACE}/node.json"
  export FAKE_CURL_BODY="${WORKSPACE}/node.json"

  # ';' is a legal but ambiguous query sub-delimiter: sent raw, a gateway that
  # still treats it as a parameter separator truncates the id and the node comes
  # back missing — which downstream reads as a permanently stale snapshot.
  run "$SCRIPT" --file abc123 --node "I12-345%3B678-901"
  [ "$status" -eq 0 ]
  run grep -c 'nodes?ids=I12:345%3B678:901' "${FAKE_CURL_LOG}"
  [ "$output" -ge 1 ]
}

@test "rejects a malformed --node before any network call" {
  run "$SCRIPT" --file abc123 --node "12-345&t=Xy9Z-4"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a Figma node id"* ]]
}

# A fake curl that routes to a different canned body per request URL, so a test
# can exercise the several distinct Figma endpoints one --node run touches: the
# whole-file fetch, the linked-node fetch, the same-file source lookup, the
# component registry, and — for cross-file resolution — the owning file's own
# node fetch. Order matters: more specific patterns are checked first.
install_url_routed_curl() {
  mkdir -p "${WORKSPACE}/bin"
  export FAKE_CURL_LOG="${WORKSPACE}/curl-args.log"
  cat > "${WORKSPACE}/bin/curl" <<'FAKE'
#!/usr/bin/env bash
[[ -n "${FAKE_CURL_LOG:-}" ]] && printf '%s\n' "$*" >> "$FAKE_CURL_LOG"
out=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|-H|--max-time) shift 2 ;;
    *) url="$1"; shift ;;
  esac
done
body=""
case "$url" in
  */components/*) body="$FAKE_CURL_COMPONENT_BODY" ;;
  */files/DSFILEKEY/*) body="$FAKE_CURL_DS_NODES_BODY" ;;
  *ids=1:1*) body="$FAKE_CURL_NODES_BODY" ;;
  *ids=9:9*) body="$FAKE_CURL_SOURCES_BODY" ;;
  */files/abc123?depth=*) body="$FAKE_CURL_FILE_BODY" ;;
  *) body="$FAKE_CURL_BODY" ;;
esac
[[ -n "$out" && -n "$body" ]] && cat "$body" > "$out"
printf '200'
FAKE
  chmod +x "${WORKSPACE}/bin/curl"
  export PATH="${WORKSPACE}/bin:${PATH}"
}

@test "resolves a source component published from another file (Design System or any library)" {
  install_url_routed_curl
  export FIGMA_PAT="figd_dummy"

  # Main file: the instance's componentId ("9:9") is a published component this
  # file references, but does not itself define — the library/Design System case.
  jq -n '{name:"f", lastModified:"2026-01-01T00:00:00Z", version:"1",
    document:{children:[]},
    components:{"9:9":{key:"PUBLISHEDKEY","name":"Button (library)"}},
    styles:{}}' > "${WORKSPACE}/file.json"
  export FAKE_CURL_FILE_BODY="${WORKSPACE}/file.json"

  # The linked node: a FRAME containing an INSTANCE of that library component.
  jq -n '{nodes:{"1:1":{document:{id:"1:1",type:"FRAME",
    children:[{id:"1:2",type:"INSTANCE",componentId:"9:9"}]}}}}' > "${WORKSPACE}/node.json"
  export FAKE_CURL_NODES_BODY="${WORKSPACE}/node.json"

  # Same-file source lookup: "9:9" is not a real node in this file.
  jq -n '{nodes:{"9:9":null}}' > "${WORKSPACE}/sources-empty.json"
  export FAKE_CURL_SOURCES_BODY="${WORKSPACE}/sources-empty.json"

  # The Figma component registry: this published key is owned by another file.
  jq -n '{meta:{key:"PUBLISHEDKEY",file_key:"DSFILEKEY",node_id:"42:42"}}' > "${WORKSPACE}/component-meta.json"
  export FAKE_CURL_COMPONENT_BODY="${WORKSPACE}/component-meta.json"

  # That other file's own node fetch: the real component definition.
  jq -n '{nodes:{"42:42":{document:{id:"42:42",name:"Button",type:"COMPONENT"}}}}' > "${WORKSPACE}/ds-node.json"
  export FAKE_CURL_DS_NODES_BODY="${WORKSPACE}/ds-node.json"

  run "$SCRIPT" --file abc123 --node 1:1
  [ "$status" -eq 0 ]

  local snap="${WORKSPACE}/.figma/cache/context-snapshot.json"
  run jq -r '.sources.nodes["9:9"].document.name' "$snap"
  [ "$output" = "Button" ]
  run jq -r '.sources.externalFiles["9:9"]' "$snap"
  [ "$output" = "DSFILEKEY" ]
  run grep -c '/components/PUBLISHEDKEY' "${FAKE_CURL_LOG}"
  [ "$output" -ge 1 ]
}

@test "degrades gracefully when a cross-file component cannot be resolved" {
  install_url_routed_curl
  export FIGMA_PAT="figd_dummy"

  # The published key has no entry in the component registry (e.g. the PAT
  # cannot read it, or Figma reports 404) — component-meta.json stays empty.
  jq -n '{name:"f", lastModified:"2026-01-01T00:00:00Z", version:"1",
    document:{children:[]},
    components:{"9:9":{key:"PUBLISHEDKEY","name":"Button (library)"}},
    styles:{}}' > "${WORKSPACE}/file.json"
  export FAKE_CURL_FILE_BODY="${WORKSPACE}/file.json"

  jq -n '{nodes:{"1:1":{document:{id:"1:1",type:"FRAME",
    children:[{id:"1:2",type:"INSTANCE",componentId:"9:9"}]}}}}' > "${WORKSPACE}/node.json"
  export FAKE_CURL_NODES_BODY="${WORKSPACE}/node.json"

  jq -n '{nodes:{"9:9":null}}' > "${WORKSPACE}/sources-empty.json"
  export FAKE_CURL_SOURCES_BODY="${WORKSPACE}/sources-empty.json"

  jq -n '{meta:{}}' > "${WORKSPACE}/component-meta.json"
  export FAKE_CURL_COMPONENT_BODY="${WORKSPACE}/component-meta.json"

  run "$SCRIPT" --file abc123 --node 1:1
  [ "$status" -eq 0 ]
  [[ "$output" == *"has no resolvable owning file"* ]]

  local snap="${WORKSPACE}/.figma/cache/context-snapshot.json"
  run jq -r '.sources.nodes["9:9"] // "absent"' "$snap"
  [ "$output" = "absent" ]
}
