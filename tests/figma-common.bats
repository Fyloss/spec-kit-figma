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

@test "a failing FIGMA_PAT_COMMAND surfaces the command's own error" {
  unset FIGMA_PAT
  cat > "${WORKSPACE}/locked-vault" <<'SH'
#!/usr/bin/env bash
echo "the vault is locked and no password was provided" >&2
exit 1
SH
  chmod +x "${WORKSPACE}/locked-vault"
  export FIGMA_PAT_COMMAND="${WORKSPACE}/locked-vault"
  run figma_load_token
  [ "$status" -ne 0 ]
  # Without the real reason, "PAT not found" sends the user back to re-storing a
  # token that is already stored — the vault, not the PAT, is the problem.
  [[ "$output" == *"the vault is locked and no password was provided"* ]]
}

@test "a failing Get-Secret lookup names the SecretStore no-password remedy" {
  unset FIGMA_PAT
  # 'Get-Secret' is a PowerShell cmdlet, so this fails outright under bash — the
  # exact shape of the Windows report (agent hook, no interactive unlock).
  export FIGMA_PAT_COMMAND="Get-Secret figma-pat -AsPlainText"
  run figma_load_token
  [ "$status" -ne 0 ]
  [[ "$output" == *"Set-SecretStoreConfiguration -Authentication None"* ]]
  [[ "$output" == *"pwsh -NoProfile -NonInteractive"* ]]
}

@test "figma_secretstore_hint stays silent for a non-SecretStore command" {
  run figma_secretstore_hint "security find-generic-password -s figma-pat -w"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
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
  [[ "$output" == *"/.figma/cache/context-snapshot.json" ]]
}

@test "figma_state_dir is the .figma directory in the workspace root" {
  run figma_state_dir
  [ "$status" -eq 0 ]
  [[ "$output" == *"/.figma" ]]
}

@test "figma_section_path points at the per-phase section under .figma" {
  run figma_section_path plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"/.figma/cache/sections/default/plan.md" ]]
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

# A fake curl that returns a 2xx success code OTHER than 200 (here 204 No
# Content, with an empty body) — exercising the contract that figma_classify_status
# already treats 201/204 as OK, so figma_api must accept them as success too.
install_no_content_curl() {
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
[[ -n "$out" ]] && : > "$out"   # 204 No Content -> empty body
printf '204'
FAKE
  chmod +x "${WORKSPACE}/bin/curl"
  export PATH="${WORKSPACE}/bin:${PATH}"
}

@test "figma_api treats a 2xx success code other than 200 (204) as success" {
  install_no_content_curl
  export FIGMA_PAT="figd_dummy"
  export FIGMA_API_BASE="https://api.figma.com/v1"
  export FIGMA_API_MAX_ATTEMPTS="1"
  export FIGMA_API_RETRY_DELAY="0"
  run figma_api "/me"
  [ "$status" -eq 0 ]
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

# --- Claude Code / official Figma plugin advisory ----------------------------

# Build a fake Claude Code config home with an installed-plugins registry whose
# "plugins" object contains the given keys (none = empty registry).
make_claude_config() {
  local home="${WORKSPACE}/claude-home"
  mkdir -p "${home}/plugins"
  local keys=""
  for k in "$@"; do
    keys="${keys:+${keys},}\"${k}\": []"
  done
  cat > "${home}/plugins/installed_plugins.json" <<JSON
{ "version": 2, "plugins": { ${keys} } }
JSON
  echo "$home"
}

@test "figma_is_claude_code is true when CLAUDECODE=1" {
  export CLAUDECODE=1
  run figma_is_claude_code
  [ "$status" -eq 0 ]
}

@test "figma_is_claude_code is true via the AI_AGENT signal" {
  unset CLAUDECODE
  export AI_AGENT="claude-code_2-1-196_agent"
  run figma_is_claude_code
  [ "$status" -eq 0 ]
}

@test "figma_is_claude_code is false outside Claude Code" {
  unset CLAUDECODE
  unset AI_AGENT
  run figma_is_claude_code
  [ "$status" -ne 0 ]
}

@test "figma_claude_figma_plugin_installed detects the official plugin" {
  export CLAUDE_CONFIG_DIR="$(make_claude_config 'figma@claude-plugins-official')"
  run figma_claude_figma_plugin_installed
  [ "$status" -eq 0 ]
}

@test "figma_claude_figma_plugin_installed detects a figma plugin from any marketplace" {
  export CLAUDE_CONFIG_DIR="$(make_claude_config 'figma@some-other-marketplace')"
  run figma_claude_figma_plugin_installed
  [ "$status" -eq 0 ]
}

@test "figma_claude_figma_plugin_installed is false when no figma plugin is present" {
  export CLAUDE_CONFIG_DIR="$(make_claude_config 'swift-lsp@claude-plugins-official')"
  run figma_claude_figma_plugin_installed
  [ "$status" -ne 0 ]
}

@test "figma_claude_figma_plugin_installed is false when the registry is absent" {
  export CLAUDE_CONFIG_DIR="${WORKSPACE}/no-such-home"
  run figma_claude_figma_plugin_installed
  [ "$status" -ne 0 ]
}

@test "figma_claude_plugin_advice recommends the plugin in Claude Code without it" {
  export CLAUDECODE=1
  unset FIGMA_NO_PLUGIN_ADVICE
  export CLAUDE_CONFIG_DIR="$(make_claude_config)"
  run figma_claude_plugin_advice
  [ "$status" -eq 0 ]
  [[ "$output" == *"figma@claude-plugins-official"* ]]
  [[ "$output" == *"mcp.figma.com/mcp"* ]]
}

@test "figma_claude_plugin_advice stays silent when the plugin is installed" {
  export CLAUDECODE=1
  unset FIGMA_NO_PLUGIN_ADVICE
  export CLAUDE_CONFIG_DIR="$(make_claude_config 'figma@claude-plugins-official')"
  run figma_claude_plugin_advice
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "figma_claude_plugin_advice stays silent outside Claude Code" {
  unset CLAUDECODE
  unset AI_AGENT
  unset FIGMA_NO_PLUGIN_ADVICE
  export CLAUDE_CONFIG_DIR="$(make_claude_config)"
  run figma_claude_plugin_advice
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "figma_claude_plugin_advice is silenced by FIGMA_NO_PLUGIN_ADVICE=1" {
  export CLAUDECODE=1
  export FIGMA_NO_PLUGIN_ADVICE=1
  export CLAUDE_CONFIG_DIR="$(make_claude_config)"
  run figma_claude_plugin_advice
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "every install hint is copy/pasteable (no '#' glued to a command)" {
  # 'apt-get install -y curl# Debian/Ubuntu' is not a comment: the shell reads
  # 'curl#' as the package name. A '#' must always follow whitespace.
  local tool
  for tool in jq curl; do
    run figma_install_hint "$tool"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    refute_glued_comment "$output"
  done
}

# --- Phase-document resolution -----------------------------------------------

stage_phase_doc() { # $1 = feature dir, $2 = phase
  mkdir -p "${WORKSPACE}/specs/$1"
  printf '# %s\n' "$1" > "${WORKSPACE}/specs/$1/$2.md"
}

@test "figma_resolve_phase_doc in identified-only mode ignores the branch's doc" {
  # The branch is a FALLBACK identity, not an override. When SPECIFY_FEATURE
  # names another feature, specs/<branch>/spec.md belongs to someone else, and a
  # caller that reads design links out of it inherits that feature's creative —
  # the very regression the link requirement exists to prevent.
  make_workspace_git "002-checkout-redesign"
  stage_phase_doc "002-checkout-redesign" spec
  export SPECIFY_FEATURE="003-redis-cache"
  run figma_resolve_phase_doc spec identified-only
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "figma_resolve_phase_doc falls back to the branch's doc in loose mode" {
  # Loose mode serves a caller that merely VERIFIES a document — its failure
  # mode is a warning, not a silent injection — so the branch stays a usable
  # guess there.
  make_workspace_git "002-checkout-redesign"
  stage_phase_doc "002-checkout-redesign" spec
  export SPECIFY_FEATURE="003-redis-cache"
  run figma_resolve_phase_doc spec
  [ "$status" -eq 0 ]
  [ "$output" = "${WORKSPACE}/specs/002-checkout-redesign/spec.md" ]
}

@test "figma_resolve_phase_doc prefers the identified feature over the branch" {
  make_workspace_git "002-checkout-redesign"
  stage_phase_doc "002-checkout-redesign" spec
  stage_phase_doc "003-redis-cache" spec
  export SPECIFY_FEATURE="003-redis-cache"
  run figma_resolve_phase_doc spec identified-only
  [ "$status" -eq 0 ]
  [ "$output" = "${WORKSPACE}/specs/003-redis-cache/spec.md" ]
}

# --- Cache housekeeping (figma_gc_cache) --------------------------------------
# The cache only ever grew: one links/<key>.json and one sections/<key>/ per
# branch that ever ran a phase, one snapshots/<file>.json per Figma file ever
# linked. Disk is not the point — a recycled branch name would hand a brand-new
# feature the remembered links of the one that used the name before it.
# 10080 minutes = the 7-day default retention window.

stage_links_entry() { # $1 = feature key, $2 = age in minutes (optional)
  mkdir -p "${WORKSPACE}/.figma/cache/links"
  printf '[{"fileId":"F1","nodeId":"1:2"}]\n' > "${WORKSPACE}/.figma/cache/links/$1.json"
  if [ -n "${2:-}" ]; then backdate_file "${WORKSPACE}/.figma/cache/links/$1.json" "$2"; fi
}

stage_sections_entry() { # $1 = feature key, $2 = age in minutes (optional)
  mkdir -p "${WORKSPACE}/.figma/cache/sections/$1"
  printf 'rendered\n' > "${WORKSPACE}/.figma/cache/sections/$1/spec.md"
  if [ -n "${2:-}" ]; then backdate_file "${WORKSPACE}/.figma/cache/sections/$1/spec.md" "$2"; fi
}

stage_stored_snapshot() { # $1 = file id, $2 = age in minutes (optional)
  mkdir -p "${WORKSPACE}/.figma/cache/snapshots"
  printf '{"fileId":"%s","pages":[]}\n' "$1" > "${WORKSPACE}/.figma/cache/snapshots/$1.json"
  if [ -n "${2:-}" ]; then backdate_file "${WORKSPACE}/.figma/cache/snapshots/$1.json" "$2"; fi
}

@test "figma_gc_cache collects an orphaned feature's remembered links" {
  # No specs/ directory means no feature ever owned this key: an ad-hoc branch,
  # or the 'default' key of a detached HEAD. Recycle the name and the next
  # feature inherits its Figma link — a design section on a feature with no
  # mockup, the regression the link requirement exists to prevent.
  export SPECIFY_FEATURE="003-redis-cache"
  stage_links_entry "throwaway-spike" 11520
  run figma_gc_cache
  [ "$status" -eq 0 ]
  [ ! -f "${WORKSPACE}/.figma/cache/links/throwaway-spike.json" ]
}

@test "figma_gc_cache keeps a key whose specs/ directory still exists" {
  # specs/<key>/ is committed, so it outlives the branch: a merged feature keeps
  # its entry however old it is. Ownership decides before age does.
  export SPECIFY_FEATURE="003-redis-cache"
  mkdir -p "${WORKSPACE}/specs/001-checkout"
  stage_links_entry "001-checkout" 43200
  run figma_gc_cache
  [ "$status" -eq 0 ]
  [ -f "${WORKSPACE}/.figma/cache/links/001-checkout.json" ]
}

@test "figma_gc_cache never collects the feature of the run doing the sweep" {
  # /speckit.specify writes the links BEFORE the specs/ directory exists, so a
  # sweep that went on ownership alone would collect the state its own run is
  # about to read back.
  export SPECIFY_FEATURE="004-brand-new"
  stage_links_entry "004-brand-new" 43200
  stage_sections_entry "004-brand-new" 43200
  run figma_gc_cache
  [ "$status" -eq 0 ]
  [ -f "${WORKSPACE}/.figma/cache/links/004-brand-new.json" ]
  [ -f "${WORKSPACE}/.figma/cache/sections/004-brand-new/spec.md" ]
}

@test "figma_gc_cache leaves a recent orphan alone until the window elapses" {
  export SPECIFY_FEATURE="003-redis-cache"
  stage_links_entry "yesterdays-branch" 1440
  run figma_gc_cache
  [ "$status" -eq 0 ]
  [ -f "${WORKSPACE}/.figma/cache/links/yesterdays-branch.json" ]
}

@test "figma_gc_cache drops an orphan's renders but never a live feature's" {
  # figma-verify-section reads "Figma applied to this run" from the EXISTENCE of
  # sections/<key>/<phase>.md. Collecting a live feature's renders would make a
  # --strict CI gate pass for a document genuinely missing its design section.
  export SPECIFY_FEATURE="003-redis-cache"
  mkdir -p "${WORKSPACE}/specs/001-checkout"
  stage_sections_entry "001-checkout" 43200
  stage_sections_entry "throwaway-spike" 11520
  run figma_gc_cache
  [ "$status" -eq 0 ]
  [ -f "${WORKSPACE}/.figma/cache/sections/001-checkout/spec.md" ]
  [ ! -d "${WORKSPACE}/.figma/cache/sections/throwaway-spike" ]
}

@test "figma_gc_cache collects stored snapshots on age alone" {
  # Snapshots are keyed by Figma file, not by feature: no owner to consult, and
  # past the freshness window snapshot_is_current would reject them anyway.
  export SPECIFY_FEATURE="003-redis-cache"
  stage_stored_snapshot "OldFILE" 11520
  stage_stored_snapshot "FreshFILE" 10
  run figma_gc_cache
  [ "$status" -eq 0 ]
  [ ! -f "${WORKSPACE}/.figma/cache/snapshots/OldFILE.json" ]
  [ -f "${WORKSPACE}/.figma/cache/snapshots/FreshFILE.json" ]
}

@test "figma_gc_cache never collects a snapshot a longer freshness window covers" {
  # A caller running with a 30-day window would still restore this snapshot; the
  # retention window is a floor, and must never cut below the caller's own.
  export SPECIFY_FEATURE="003-redis-cache"
  export FIGMA_SNAPSHOT_MAX_AGE_MINUTES=43200
  stage_stored_snapshot "LongWindowFILE" 11520
  run figma_gc_cache
  [ "$status" -eq 0 ]
  [ -f "${WORKSPACE}/.figma/cache/snapshots/LongWindowFILE.json" ]
}

@test "figma_gc_cache leaves the current-run snapshot slot alone" {
  # context-snapshot.json is the path every command prompt hands to the agent,
  # not a per-key entry: sweeping it would pull the design facts out from under
  # a run that already decided they were fresh.
  export SPECIFY_FEATURE="003-redis-cache"
  printf '{"fileId":"F1"}\n' > "${WORKSPACE}/.figma/cache/context-snapshot.json"
  backdate_file "${WORKSPACE}/.figma/cache/context-snapshot.json" 43200
  run figma_gc_cache
  [ "$status" -eq 0 ]
  [ -f "${WORKSPACE}/.figma/cache/context-snapshot.json" ]
}

@test "figma_gc_cache sweeps at most once a day, and =force overrides that" {
  # It runs inside a hook fired on every phase; a full sweep per phase is waste.
  export SPECIFY_FEATURE="003-redis-cache"
  run figma_gc_cache
  [ "$status" -eq 0 ]
  [ -f "${WORKSPACE}/.figma/cache/.gc-stamp" ]

  stage_links_entry "throwaway-spike" 11520
  run figma_gc_cache
  [ "$status" -eq 0 ]
  [ -f "${WORKSPACE}/.figma/cache/links/throwaway-spike.json" ]

  FIGMA_CACHE_GC=force run figma_gc_cache
  [ "$status" -eq 0 ]
  [ ! -f "${WORKSPACE}/.figma/cache/links/throwaway-spike.json" ]
}

@test "figma_gc_cache honours FIGMA_CACHE_GC=off and FIGMA_CACHE_RETENTION_DAYS" {
  export SPECIFY_FEATURE="003-redis-cache"
  stage_links_entry "throwaway-spike" 11520
  FIGMA_CACHE_GC=off run figma_gc_cache
  [ "$status" -eq 0 ]
  [ -f "${WORKSPACE}/.figma/cache/links/throwaway-spike.json" ]

  # 30 days: the same entry is now well inside the window.
  FIGMA_CACHE_RETENTION_DAYS=30 FIGMA_CACHE_GC=force run figma_gc_cache
  [ "$status" -eq 0 ]
  [ -f "${WORKSPACE}/.figma/cache/links/throwaway-spike.json" ]

  FIGMA_CACHE_RETENTION_DAYS=1 FIGMA_CACHE_GC=force run figma_gc_cache
  [ "$status" -eq 0 ]
  [ ! -f "${WORKSPACE}/.figma/cache/links/throwaway-spike.json" ]
}

@test "figma_gc_cache reports what it reclaimed, and how to tune it" {
  # Silent deletion of state a developer may be debugging is not acceptable; the
  # line is the only place the two knobs are ever surfaced.
  export SPECIFY_FEATURE="003-redis-cache"
  stage_links_entry "throwaway-spike" 11520
  run figma_gc_cache
  [ "$status" -eq 0 ]
  [[ "$output" == *"reclaimed 1 stale entry"* ]]
  [[ "$output" == *"FIGMA_CACHE_RETENTION_DAYS"* ]]
  [[ "$output" == *"FIGMA_CACHE_GC=off"* ]]
}
