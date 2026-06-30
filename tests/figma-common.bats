#!/usr/bin/env bats
# Tests for the shared helpers in scripts/bash/figma-common.sh

load helpers/common

setup() {
  WORKSPACE="$(make_temp_workspace)"
  cd "$WORKSPACE"
  # shellcheck source=/dev/null
  source "${SCRIPTS_DIR}/figma-common.sh"
}

teardown() {
  cd "$REPO_ROOT"
  [ -n "$WORKSPACE" ] && rm -rf "$WORKSPACE"
}

@test "figma_env_var_name defaults to FIGMA_PAT without a config" {
  run figma_env_var_name "${WORKSPACE}/missing-config.json"
  [ "$status" -eq 0 ]
  [ "$output" = "FIGMA_PAT" ]
}

@test "figma_env_var_name reads the custom envVar from the config" {
  cat > "${WORKSPACE}/figma.projects.config.json" <<'JSON'
{ "figma": { "credentials": { "envVar": "MY_FIGMA_TOKEN" } } }
JSON
  run figma_env_var_name "${WORKSPACE}/figma.projects.config.json"
  [ "$status" -eq 0 ]
  [ "$output" = "MY_FIGMA_TOKEN" ]
}

@test "figma_load_token reads the token from the environment" {
  export FIGMA_PAT="figd_env_token_value"
  run figma_load_token
  [ "$status" -eq 0 ]
  [ "$output" = "figd_env_token_value" ]
}

@test "figma_load_token fails when no env var and no keychain command are set" {
  unset FIGMA_PAT
  unset FIGMA_PAT_COMMAND
  run figma_load_token
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "figma_load_token never reads a plaintext .env file" {
  unset FIGMA_PAT
  unset FIGMA_PAT_COMMAND
  printf 'FIGMA_PAT=figd_from_dotenv\n' > "${WORKSPACE}/.env"
  run figma_load_token
  [ "$status" -ne 0 ]
  [[ "$output" != *"figd_from_dotenv"* ]]
}

@test "figma_load_token fetches the token via FIGMA_PAT_COMMAND when the env var is unset" {
  unset FIGMA_PAT
  export FIGMA_PAT_COMMAND="printf figd_from_command"
  run figma_load_token
  [ "$status" -eq 0 ]
  [ "$output" = "figd_from_command" ]
}

@test "the environment variable wins over FIGMA_PAT_COMMAND" {
  export FIGMA_PAT="figd_env_token"
  export FIGMA_PAT_COMMAND="printf figd_from_command"
  run figma_load_token
  [ "$status" -eq 0 ]
  [ "$output" = "figd_env_token" ]
}

@test "a failing FIGMA_PAT_COMMAND errors (no .env fallback)" {
  unset FIGMA_PAT
  printf 'FIGMA_PAT=figd_dotenv\n' > "${WORKSPACE}/.env"
  export FIGMA_PAT_COMMAND="false"
  run figma_load_token
  [ "$status" -ne 0 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"not found"* ]]
  [[ "$output" != *"figd_dotenv"* ]]
}

@test "FIGMA_PAT_COMMAND is executed without a shell (no pipe smuggling)" {
  unset FIGMA_PAT
  export FIGMA_PAT_COMMAND="printf figd_a | tr a b"
  run figma_load_token
  [ "$status" -eq 0 ]
  # Tokenized exec: '|', 'tr', 'a', 'b' are plain printf arguments, not a pipeline.
  [[ "$output" != "figd_b" ]]
}

@test "figma_cache_path points at the snapshot under the .figma state dir" {
  run figma_cache_path
  [ "$status" -eq 0 ]
  [[ "$output" == *"/.figma/context-snapshot.json" ]]
}

@test "figma_state_dir is the .figma directory in the workspace root" {
  run figma_state_dir
  [ "$status" -eq 0 ]
  [[ "$output" == *"/.figma" ]]
}

@test "figma_section_path points at the per-phase section under .figma" {
  run figma_section_path plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"/.figma/section.plan.md" ]]
}

@test "figma_context_source defaults to rest without a config" {
  run figma_context_source "${WORKSPACE}/missing-config.json"
  [ "$status" -eq 0 ]
  [ "$output" = "rest" ]
}

@test "figma_context_source reads mcp from the config" {
  cat > "${WORKSPACE}/figma.projects.config.json" <<'JSON'
{ "figma": { "contextSource": "mcp" } }
JSON
  run figma_context_source "${WORKSPACE}/figma.projects.config.json"
  [ "$status" -eq 0 ]
  [ "$output" = "mcp" ]
}

@test "figma_mcp_url defaults to the local Dev Mode server" {
  run figma_mcp_url "${WORKSPACE}/missing-config.json"
  [ "$status" -eq 0 ]
  [ "$output" = "http://127.0.0.1:3845/mcp" ]
}

@test "figma_mcp_fallback_enabled defaults to true" {
  run figma_mcp_fallback_enabled "${WORKSPACE}/missing-config.json"
  [ "$status" -eq 0 ]
}

@test "figma_mcp_fallback_enabled honors fallbackToRest=false" {
  cat > "${WORKSPACE}/figma.projects.config.json" <<'JSON'
{ "figma": { "mcp": { "fallbackToRest": false } } }
JSON
  run figma_mcp_fallback_enabled "${WORKSPACE}/figma.projects.config.json"
  [ "$status" -ne 0 ]
}

@test "figma_resolve_context_source returns rest by default" {
  cat > "${WORKSPACE}/figma.projects.config.json" <<'JSON'
{ "figma": { "contextSource": "rest" } }
JSON
  run figma_resolve_context_source "${WORKSPACE}/figma.projects.config.json"
  [ "$status" -eq 0 ]
  [ "$output" = "rest" ]
}

@test "figma_resolve_context_source falls back to rest when MCP is unreachable" {
  cat > "${WORKSPACE}/figma.projects.config.json" <<'JSON'
{ "figma": { "contextSource": "mcp", "mcp": { "url": "http://127.0.0.1:9/mcp" } } }
JSON
  run figma_resolve_context_source "${WORKSPACE}/figma.projects.config.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rest"* ]]
  [[ "$output" == *"falling back"* ]]
}

@test "figma_env_var_name prefers envVar over secretName in ci-secret mode" {
  cat > "${WORKSPACE}/figma.projects.config.json" <<'JSON'
{ "figma": { "credentials": { "source": "ci-secret", "secretName": "ORG_FIGMA_TOKEN", "envVar": "FIGMA_PAT_RUNTIME" } } }
JSON
  run figma_env_var_name "${WORKSPACE}/figma.projects.config.json"
  [ "$status" -eq 0 ]
  [ "$output" = "FIGMA_PAT_RUNTIME" ]
}

@test "figma_env_var_name falls back to secretName in ci-secret mode without envVar" {
  cat > "${WORKSPACE}/figma.projects.config.json" <<'JSON'
{ "figma": { "credentials": { "source": "ci-secret", "secretName": "ORG_FIGMA_TOKEN" } } }
JSON
  run figma_env_var_name "${WORKSPACE}/figma.projects.config.json"
  [ "$status" -eq 0 ]
  [ "$output" = "ORG_FIGMA_TOKEN" ]
}

@test "figma_load_token honors FIGMA_CONFIG for a custom config path" {
  unset FIGMA_PAT
  mkdir -p "${WORKSPACE}/custom"
  cat > "${WORKSPACE}/custom/figma.json" <<'JSON'
{ "figma": { "credentials": { "source": "env", "envVar": "MY_CUSTOM_FIGMA_TOKEN" } } }
JSON
  export FIGMA_CONFIG="${WORKSPACE}/custom/figma.json"
  export MY_CUSTOM_FIGMA_TOKEN="figd_custom_token"
  run figma_load_token
  [ "$status" -eq 0 ]
  [ "$output" = "figd_custom_token" ]
}

@test "figma_api retries transport failures instead of failing on a garbled code" {
  export FIGMA_PAT="figd_dummy"
  export FIGMA_API_BASE="http://127.0.0.1:9"
  export FIGMA_API_MAX_ATTEMPTS="2"
  export FIGMA_API_RETRY_DELAY="0"
  run figma_api "/files/test"
  [ "$status" -ne 0 ]
  [[ "$output" != *"000000"* ]]
  # An exhausted transport failure is reported as a NETWORK error, never auth.
  [[ "$output" == *"NETWORK/PROXY error"* ]]
  [[ "$output" == *"cannot reach api.figma.com"* ]]
  [[ "$output" != *"authentication required"* ]]
}

# --- HTTP status classification (pure unit, no network) ----------------------

@test "figma_classify_status maps transport/proxy failure (000) to NETWORK" {
  run figma_classify_status 000
  [ "$status" -eq 0 ]
  [ "$output" = "NETWORK" ]
}

@test "figma_classify_status maps 401 and 403 to AUTH" {
  run figma_classify_status 401
  [ "$output" = "AUTH" ]
  run figma_classify_status 403
  [ "$output" = "AUTH" ]
}

@test "figma_classify_status maps 404 to NOT_FOUND" {
  run figma_classify_status 404
  [ "$output" = "NOT_FOUND" ]
}

@test "figma_classify_status maps 429 to RATE_LIMIT and 5xx to SERVER" {
  run figma_classify_status 429
  [ "$output" = "RATE_LIMIT" ]
  run figma_classify_status 503
  [ "$output" = "SERVER" ]
}

# --- Cause-specific diagnostics ----------------------------------------------

@test "figma_error_message NETWORK never mentions authentication" {
  run figma_error_message NETWORK "/files/abc" 000
  [[ "$output" == *"NETWORK/PROXY"* ]]
  [[ "$output" == *"proxy"* ]]
  [[ "$output" != *"authentication required"* ]]
}

@test "figma_error_message AUTH points at CREDENTIALS and forbids .env" {
  run figma_error_message AUTH "/teams/123/projects" 403
  [[ "$output" == *"AUTH/SCOPE"* ]]
  [[ "$output" == *"CREDENTIALS.md"* ]]
  [[ "$output" == *"projects:read"* ]]
  [[ "$output" == *".env"* ]]
}

@test "figma_error_message NOT_FOUND mentions membership" {
  run figma_error_message NOT_FOUND "/files/abc" 404
  [[ "$output" == *"NOT FOUND"* ]]
  [[ "$output" == *"member"* ]]
}

# --- Proxy self-heal: broken proxy, direct retry succeeds --------------------

# A fake curl that fails (exit 5, "couldn't resolve proxy") whenever a proxy var
# is set, and succeeds (HTTP 200 + body) once the proxy is stripped. This models
# the measured corporate case: proxy -> exit 5; direct -> 200.
install_proxy_breaking_curl() {
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
if [[ -n "${HTTP_PROXY:-}${HTTPS_PROXY:-}${http_proxy:-}${https_proxy:-}" ]]; then
  printf '000'; exit 5
fi
[[ -n "$out" ]] && printf '{"name":"ok"}' > "$out"
printf '200'
FAKE
  chmod +x "${WORKSPACE}/bin/curl"
  export PATH="${WORKSPACE}/bin:${PATH}"
}

@test "figma_api self-heals a broken proxy by retrying directly" {
  install_proxy_breaking_curl
  export FIGMA_PAT="figd_dummy"
  export FIGMA_API_BASE="https://api.figma.com/v1"
  export FIGMA_API_MAX_ATTEMPTS="1"
  export FIGMA_API_RETRY_DELAY="0"
  export HTTPS_PROXY="http://broken-proxy.invalid:8080"
  export HTTP_PROXY="$HTTPS_PROXY"
  run figma_api "/me"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"name":"ok"'* ]]
}

@test "figma_api never echoes the PAT, even on the proxy retry path" {
  install_proxy_breaking_curl
  export FIGMA_PAT="figd_SECRET_TOKEN_DO_NOT_LEAK"
  export FIGMA_API_BASE="https://api.figma.com/v1"
  export FIGMA_API_MAX_ATTEMPTS="1"
  export FIGMA_API_RETRY_DELAY="0"
  export HTTPS_PROXY="http://broken-proxy.invalid:8080"
  run figma_api "/me"
  [[ "$output" != *"figd_SECRET_TOKEN_DO_NOT_LEAK"* ]]
}

@test "figma_api_base rejects a non-figma.com host from the config" {
  unset FIGMA_API_BASE
  cat > "${WORKSPACE}/figma.projects.config.json" <<'JSON'
{ "figma": { "apiBaseUrl": "https://attacker.example.com/v1" } }
JSON
  run figma_api_base "${WORKSPACE}/figma.projects.config.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing apiBaseUrl"* ]]
}

@test "figma_api_base rejects a non-https apiBaseUrl from the config" {
  unset FIGMA_API_BASE
  cat > "${WORKSPACE}/figma.projects.config.json" <<'JSON'
{ "figma": { "apiBaseUrl": "http://api.figma.com/v1" } }
JSON
  run figma_api_base "${WORKSPACE}/figma.projects.config.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing apiBaseUrl"* ]]
}

@test "figma_api_base rejects a figma.com lookalike host" {
  unset FIGMA_API_BASE
  cat > "${WORKSPACE}/figma.projects.config.json" <<'JSON'
{ "figma": { "apiBaseUrl": "https://api.figma.com.evil.example/v1" } }
JSON
  run figma_api_base "${WORKSPACE}/figma.projects.config.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing apiBaseUrl"* ]]
}

@test "figma_api_base rejects a host smuggled behind a query string" {
  unset FIGMA_API_BASE
  cat > "${WORKSPACE}/figma.projects.config.json" <<'JSON'
{ "figma": { "apiBaseUrl": "https://evil.example?x=.figma.com" } }
JSON
  run figma_api_base "${WORKSPACE}/figma.projects.config.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing apiBaseUrl"* ]]
}

@test "figma_api_base accepts the official figma.com host from the config" {
  unset FIGMA_API_BASE
  cat > "${WORKSPACE}/figma.projects.config.json" <<'JSON'
{ "figma": { "apiBaseUrl": "https://api.figma.com/v1" } }
JSON
  run figma_api_base "${WORKSPACE}/figma.projects.config.json"
  [ "$status" -eq 0 ]
  [ "$output" = "https://api.figma.com/v1" ]
}

@test "figma_api refuses to send the token to a config-provided non-figma host" {
  unset FIGMA_API_BASE
  export FIGMA_PAT="figd_dummy"
  export FIGMA_API_MAX_ATTEMPTS="1"
  export FIGMA_API_RETRY_DELAY="0"
  cat > "${WORKSPACE}/figma.projects.config.json" <<'JSON'
{ "figma": { "apiBaseUrl": "https://attacker.example.com/v1" } }
JSON
  run figma_api "/files/test"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing apiBaseUrl"* ]]
}

@test "figma_resolve_context_source errors when MCP unreachable and fallback disabled" {
  cat > "${WORKSPACE}/figma.projects.config.json" <<'JSON'
{ "figma": { "contextSource": "mcp", "mcp": { "url": "http://127.0.0.1:9/mcp", "fallbackToRest": false } } }
JSON
  run figma_resolve_context_source "${WORKSPACE}/figma.projects.config.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unreachable"* ]]
}

@test "figma_scope_hint points project/team 403s at the projects:read scope" {
  run figma_scope_hint "/projects/123/files"
  [ "$status" -eq 0 ]
  [[ "$output" == *"projects:read"* ]]
  run figma_scope_hint "/teams/456/projects"
  [[ "$output" == *"projects:read"* ]]
  [[ "$output" == *"member of that team"* ]]
}

@test "figma_scope_hint points file 403s at the file_content:read scope" {
  run figma_scope_hint "/files/AbC123?depth=2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"file_content:read"* ]]
  [[ "$output" != *"projects:read"* ]]
}
