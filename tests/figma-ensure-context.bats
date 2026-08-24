#!/usr/bin/env bats
# Tests for scripts/bash/figma-ensure-context.sh (automatic pre-specify/tasks hook)

load helpers/common

setup() {
  SCRIPT="${SCRIPTS_DIR}/figma-ensure-context.sh"
  WORKSPACE="$(make_temp_workspace)"
  cd "$WORKSPACE"
  # A Figma link is now what makes a run a design run, so every test that
  # exercises the applicable path has to carry one.
  LINK="https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345"
  # Each test is its own feature: remembered links are scoped per feature, and a
  # stable key keeps them from bleeding across tests via the shared temp dir.
  export SPECIFY_FEATURE="test-${BATS_TEST_NUMBER}"
}

teardown() {
  cd "$REPO_ROOT"
  [ -n "$WORKSPACE" ] && rm -rf "$WORKSPACE"
}

# Extract the trailing JSON status object from mixed stderr/stdout output.
status_json() {
  echo "$output" | sed -n '/^{/,$p'
}

# A PATH holding only the few tools the pre-flight path needs — jq excluded —
# so the hook can be exercised on a machine where jq was never installed.
path_without_jq() {
  local sandbox="${WORKSPACE}/nojq-bin" tool resolved
  mkdir -p "$sandbox"
  for tool in bash dirname sed cat grep git; do
    resolved="$(command -v "$tool" || true)"
    [ -n "$resolved" ] && ln -sf "$resolved" "${sandbox}/${tool}"
  done
  printf '%s' "$sandbox"
}

@test "missing config is a safe no-op (exit 0, reason no-config)" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.ran')" == "false" ]]
  [[ "$(status_json | jq -r '.reason')" == "no-config" ]]
}

@test "unresolved placeholders skip without blocking" {
  cp "${FIXTURES_DIR}/unresolved-placeholder.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "unresolved-placeholders" ]]
}

@test "invalid config skips without blocking" {
  echo '{ "mode": "what" }' > "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "invalid-config" ]]
}

@test "excluded target skips silently" {
  cp "${FIXTURES_DIR}/multirepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" back-bff
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "target-excluded" ]]
}

@test "single-repo resolves the target to repo" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --dry-run --input "$LINK"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "dry-run" ]]
  [[ "$(status_json | jq -r '.target')" == "repo" ]]
}

@test "multi-repo with a single enabled target auto-resolves it" {
  cp "${FIXTURES_DIR}/multirepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --dry-run --input "$LINK"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.target')" == "design-system" ]]
  [[ "$(status_json | jq -r '.reason')" == "dry-run" ]]
}

@test "multi-repo with several enabled targets requires an explicit target" {
  cat > "${WORKSPACE}/figma.projects.config.json" <<'JSON'
{
  "version": "1.0",
  "mode": "multi-repo",
  "figma": { "credentials": { "source": "env" } },
  "submodules": {
    "app-a": { "enabled": true, "role": "app", "figmaFileId": "fileA" },
    "app-b": { "enabled": true, "role": "app", "figmaFileId": "fileB" }
  }
}
JSON
  run "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "ambiguous-target" ]]
}

@test "a team-based config still gates on the link" {
  # The team mapping used to drive a --team introspection on its own; the link
  # is now the trigger, so a design-less run stops here.
  cp "${FIXTURES_DIR}/organization-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" design-system --dry-run
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "no-figma-link" ]]
}

@test "a fresh snapshot covering the link skips introspection" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{"fileId":"LinkFILE999","nodes":{"nodes":{"12:345":{}}}}' \
    > "${WORKSPACE}/.figma/cache/context-snapshot.json"
  run "$SCRIPT" --input "$LINK"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.ran')" == "false" ]]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
}

@test "a config newer than the snapshot forces re-introspection" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{"fileId":"LinkFILE999","nodes":{"nodes":{"12:345":{}}}}' \
    > "${WORKSPACE}/.figma/cache/context-snapshot.json"
  touch -t 202601010000 "${WORKSPACE}/.figma/cache/context-snapshot.json"
  run "$SCRIPT" --dry-run --input "$LINK"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "dry-run" ]]
}

@test "a failed introspection is reported but never blocks (exit 0)" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  unset FIGMA_PAT
  unset FIGMA_PAT_COMMAND
  run "$SCRIPT" --input "$LINK"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.ran')" == "false" ]]
  [[ "$(status_json | jq -r '.reason')" == "introspect-failed" ]]
  # No-token is a credentials problem, surfaced as a machine-readable AUTH code
  # (never a silent no-op, never a fabricated network cause).
  [[ "$(status_json | jq -r '.code')" == "AUTH" ]]
}

@test "a network/proxy introspection failure propagates code NETWORK, not auth" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  export FIGMA_PAT="figd_dummy"
  # Unreachable base => transport failure (000) => NETWORK, not AUTH.
  export FIGMA_API_BASE="http://127.0.0.1:9/v1"
  export FIGMA_API_MAX_ATTEMPTS="1"
  export FIGMA_API_RETRY_DELAY="0"
  run "$SCRIPT" --input "$LINK"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "introspect-failed" ]]
  [[ "$(status_json | jq -r '.code')" == "NETWORK" ]]
  [[ "$output" != *"authentication required"* ]]
}

@test "rejects a non-numeric --max-age-minutes" {
  run "$SCRIPT" --max-age-minutes never
  [ "$status" -eq 1 ]
  [[ "$output" == *"--max-age-minutes must be a positive integer"* ]]
}

# --- Direct Figma links in the feature input (--input) -----------------------

@test "--input with a direct Figma link plans introspection of the linked file and node" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --dry-run --input \
    "Build the checkout page https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "dry-run" ]]
  [[ "$(status_json | jq -r '.introspectArgs | join(" ")')" == "--file LinkFILE999 --node 12:345" ]]
  [[ "$(status_json | jq -r '.links | length')" == "1" ]]
  [[ "$(status_json | jq -r '.links[0].nodeId')" == "12:345" ]]
}

@test "--input - reads the feature description from stdin" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run bash -c "printf '%s' 'See https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345' \
    | \"$SCRIPT\" --dry-run --input -"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.introspectArgs | join(" ")')" == "--file LinkFILE999 --node 12:345" ]]
}

@test "a link without node-id introspects the linked file only" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --dry-run --input "https://www.figma.com/design/LinkFILE999/Checkout"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.introspectArgs | join(" ")')" == "--file LinkFILE999" ]]
}

@test "several links to the same file dedupe into one file and multiple nodes" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --dry-run --input \
    "https://www.figma.com/design/LinkFILE999/A?node-id=1-2 and https://www.figma.com/design/LinkFILE999/A?node-id=3-4"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.introspectArgs | join(" ")')" == "--file LinkFILE999 --node 1:2 --node 3:4" ]]
}

@test "links to several files use the first and surface a warning" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --dry-run --input \
    "https://www.figma.com/design/FirstFILE/A?node-id=1-2 https://www.figma.com/design/SecondFILE/B?node-id=3-4"
  [ "$status" -eq 0 ]
  [[ "$output" == *"distinct Figma files"* ]]
  [[ "$(status_json | jq -r '.introspectArgs | join(" ")')" == "--file FirstFILE --node 1:2" ]]
}

# --- A Figma link is what makes a run a design run --------------------------
# Regression: with a valid config and an enabled target, the hook used to
# introspect and render the mandatory section for EVERY feature — including
# "add a Redis cache on the billing endpoint" — so spec.md got a Figma design
# section it had no business carrying. The link in the feature input is now the
# trigger; without one the hook is a no-op.

@test "input without links is a no-op (reason no-figma-link)" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --dry-run --input "No design links in this feature."
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.ran')" == "false" ]]
  [[ "$(status_json | jq -r '.reason')" == "no-figma-link" ]]
  [[ "$(status_json | jq -r '.links | length')" == "0" ]]
  [[ "$(status_json | jq -r '.introspectArgs | length')" == "0" ]]
}

@test "no input at all is a no-op, whatever the config maps" {
  # The config maps the target to a Figma file, but nothing in this run points
  # at a creative: the mapping alone must not force a design section.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "no-figma-link" ]]
}

@test "a link-less run injects nothing and renders no section" {
  # The heart of the regression: mustInject false and NO section.*.md on disk,
  # so the after_* verify hooks report not-applicable instead of demanding a
  # section the document should never have had.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{"fileId":"single123FILE","pages":[{"id":"0:1","name":"Home","frames":[{"id":"1:2","name":"Hero","type":"FRAME"}]}]}' \
    > "${WORKSPACE}/.figma/cache/context-snapshot.json"
  run "$SCRIPT" --input "Add a Redis cache on the billing endpoint."
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "no-figma-link" ]]
  [[ "$(status_json | jq -r '.mustInject')" == "false" ]]
  [[ "$(status_json | jq -r '.specSection')" == "null" ]]
  [ ! -f "$(section_path spec)" ]
  [ ! -f "$(section_path plan)" ]
  [ ! -f "$(section_path tasks)" ]
}

@test "the no-figma-link diagnostic names the remedy" {
  # The document stays silent, so the console is the ONLY place a forgotten link
  # can still be caught — and only if the line says what to do about it. A
  # front-end feature whose author forgot to paste the link is otherwise
  # indistinguishable from a back-end one, all the way through plan and tasks.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --input "Build the new checkout screen."
  [ "$status" -eq 0 ]
  [[ "$output" == *"/speckit.specify"* ]]
  [[ "$output" == *"re-run"* ]]
}

@test "the ensure command doc does not list no-figma-link among the note-worthy reasons" {
  # "Other skip reasons" tells the agent to add a short note naming the reason.
  # Listing no-figma-link there contradicts the section right below it, which
  # requires adding NOTHING — and a contradiction in the prompt is resolved by
  # the model, differently each time.
  doc="${REPO_ROOT}/commands/speckit.figma.ensure.md"
  paragraph="$(awk '/^For any other `reason`/{f=1} f && NF {print} f && !NF {exit}' "$doc")"
  [ -n "$paragraph" ]
  ! grep -qF 'no-figma-link' <<< "$paragraph"
}

@test "the ensure command doc separates the document from the chat reply" {
  # "Add NOTHING" must scope to the generated document only. Applied to the
  # agent's own reply as well, it suppresses the one signal a developer can act
  # on while the run is still fresh.
  doc="${REPO_ROOT}/commands/speckit.figma.ensure.md"
  grep -qiF "chat reply" "$doc"
  grep -qiF "do not ask" "$doc"
}

@test "a link-less feature does not wipe another feature's rendered section" {
  # The rendered section is what tells figma-verify-section that Figma applied
  # to a run. While it lived in one global slot, a design-less feature B erased
  # feature A's — so A's after-hook reported not-applicable and a --strict CI
  # gate passed for a document that was genuinely missing its design section.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  export SPECIFY_FEATURE="001-checkout"
  echo '{"fileId":"LinkFILE999","pages":[{"id":"0:1","name":"Home","frames":[{"id":"12:345","name":"Hero","type":"FRAME"}]}],"nodes":{"nodes":{"12:345":{"document":{"type":"FRAME"}}}}}' \
    > "${WORKSPACE}/.figma/cache/context-snapshot.json"
  run "$SCRIPT" --input "https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
  a_section="$(status_json | jq -r '.specSection')"
  [ -f "$a_section" ]

  # Feature B has no mockup at all: its run must clear ITS OWN renders only.
  export SPECIFY_FEATURE="002-billing-cache"
  run "$SCRIPT" --input "Add a Redis cache on the billing endpoint."
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "no-figma-link" ]]
  [ -f "$a_section" ]
}

@test "no-figma-link clears a stale rendered section from a previous feature" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  stage_section spec stale
  run "$SCRIPT" --input "Pure backend refactor."
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "no-figma-link" ]]
  [ ! -f "$(section_path spec)" ]
}

# --- The link is required at /speckit.specify, then inherited ----------------
# The developer pastes the link once, when describing the feature. /speckit.plan
# and /speckit.tasks receive a different input that no longer carries it, so the
# links detected at specify time are remembered per feature and reused — without
# that, spec.md would carry a design section and plan.md would not.

@test "a link is remembered so a later link-less phase still applies" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  export SPECIFY_FEATURE="001-checkout"
  # /speckit.specify: a real run, so the link is recorded (introspection then
  # fails for lack of a token, which is beside the point here).
  run "$SCRIPT" --input \
    "https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345"
  [ "$status" -eq 0 ]

  # /speckit.plan: same feature, no link in this phase's input.
  run "$SCRIPT" --dry-run --input "Draft the implementation plan."
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "dry-run" ]]
  [[ "$(status_json | jq -r '.introspectArgs | join(" ")')" == "--file LinkFILE999 --node 12:345" ]]
  [[ "$(status_json | jq -r '.links[0].nodeId')" == "12:345" ]]
}

@test "remembered links are scoped to their feature, never leaking to the next" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  export SPECIFY_FEATURE="001-checkout"
  run "$SCRIPT" --input "https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345"
  [ "$status" -eq 0 ]

  # A brand-new, design-less feature must not inherit the previous one's link.
  export SPECIFY_FEATURE="002-billing-cache"
  run "$SCRIPT" --input "Add a Redis cache on the billing endpoint."
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "no-figma-link" ]]
}

@test "a corrupt remembered-links file degrades to no-figma-link, never a crash" {
  # The never-block contract holds even when the cache is damaged: a truncated
  # or hand-edited file must not abort the script under set -e.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  export SPECIFY_FEATURE="001-checkout"
  mkdir -p "${WORKSPACE}/.figma/cache/links"
  printf '{"not":"an array"' > "${WORKSPACE}/.figma/cache/links/001-checkout.json"
  run "$SCRIPT" --input "No link in this phase."
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "no-figma-link" ]]
}

@test "a remembered-links file whose JSON root is not an array is ignored" {
  # Valid JSON, plausible content, wrong shape: a hand-edited file holding a
  # single object instead of a one-element array. Accepting it would feed a
  # value the rest of the pipeline treats as a list, so the contract is the JSON
  # ROOT TYPE, not merely "does it parse". Pinned in both ports: PowerShell's
  # ConvertFrom-Json unrolls a one-element array into a bare object, so the
  # deserialized shape alone cannot tell the two apart.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  export SPECIFY_FEATURE="001-checkout"
  mkdir -p "${WORKSPACE}/.figma/cache/links"
  printf '{"fileId":"LinkFILE999","nodeId":"12:345"}' \
    > "${WORKSPACE}/.figma/cache/links/001-checkout.json"
  run "$SCRIPT" --dry-run --input "No link in this phase."
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "no-figma-link" ]]
}

@test "a remembered-links entry carrying no fileId degrades to no-figma-link" {
  # The root type is an array and the file parses, so the shape guard above
  # passes — but the entry itself has no fileId. Reading it out unguarded yields
  # jq's literal "null", which is non-empty and therefore looks like a real file
  # key: the run would go on to introspect /files/null and report a failure
  # instead of staying silent about Figma.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  export SPECIFY_FEATURE="001-checkout"
  mkdir -p "${WORKSPACE}/.figma/cache/links"
  printf '[{"nodeId":"12:345","url":"https://www.figma.com/design/"}]' \
    > "${WORKSPACE}/.figma/cache/links/001-checkout.json"
  run "$SCRIPT" --dry-run --input "No link in this phase."
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "no-figma-link" ]]
}

@test "a dry run never records the links it detected" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  export SPECIFY_FEATURE="001-checkout"
  run "$SCRIPT" --dry-run --input \
    "https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345"
  [ "$status" -eq 0 ]
  run "$SCRIPT" --input "No link in this phase."
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "no-figma-link" ]]
}

# --- The committed spec.md is the durable record of the link ------------------
# .figma/cache/ is git-ignored, so the remembered links do NOT travel with the
# branch: a teammate who pulls it, a fresh clone or a CI job reaches
# /speckit.plan with the spec but no cache. Falling through to "no-figma-link"
# there tells the agent to say NOTHING about Figma, so plan.md silently loses the
# design section spec.md carries. spec.md itself is the fallback.

# Write a spec.md carrying an integrated Figma section for the current feature.
stage_spec_with_section() { # $1 = feature dir, $2 = link URL
  mkdir -p "${WORKSPACE}/specs/$1"
  {
    printf '# Checkout\n\n'
    printf '<!-- speckit-figma:section phase=spec -->\n'
    printf '## Figma Design Context\n\n'
    printf '**Direct links provided in input**\n\n'
    printf '| URL | File | Node |\n|-----|------|------|\n'
    printf '| %s | `x` | `x` |\n' "$2"
  } > "${WORKSPACE}/specs/$1/spec.md"
}

@test "a lost links cache falls back to the link recorded in spec.md" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  export SPECIFY_FEATURE="001-checkout"
  stage_spec_with_section "001-checkout" \
    "https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345"
  # No .figma/cache/links/ at all — the cache never crossed the git boundary.
  run "$SCRIPT" --dry-run --input "Draft the implementation plan."
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "dry-run" ]]
  [[ "$(status_json | jq -r '.introspectArgs | join(" ")')" == "--file LinkFILE999 --node 12:345" ]]
}

@test "spec.md is a link source only when it carries the Figma section marker" {
  # A figma.com URL merely mentioned in prose is not evidence that a design
  # section was ever integrated; only the machine marker is.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  export SPECIFY_FEATURE="001-checkout"
  mkdir -p "${WORKSPACE}/specs/001-checkout"
  printf '# Checkout\n\nSee https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345 for background.\n' \
    > "${WORKSPACE}/specs/001-checkout/spec.md"
  run "$SCRIPT" --dry-run --input "Draft the implementation plan."
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "no-figma-link" ]]
}

@test "another feature's spec.md is never a link source" {
  # The document is only evidence for the feature it belongs to. Falling back to
  # "the single specs/*/spec.md" when nothing identifies the current feature
  # would hand a design-less feature the previous one's creative — the very
  # regression the link requirement exists to prevent.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  unset SPECIFY_FEATURE
  stage_spec_with_section "001-checkout" \
    "https://www.figma.com/design/OtherFEATURE/Checkout?node-id=12-345"
  run "$SCRIPT" --dry-run --input "Add a Redis cache on the billing endpoint."
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "no-figma-link" ]]
}

@test "the checked-out branch's spec.md is never another feature's link source" {
  # SPECIFY_FEATURE identifies the feature; the branch only stands in when
  # nothing else does. When the two diverge — a new feature started while the
  # branch still carries the previous one's document — specs/<branch>/spec.md
  # belongs to ANOTHER feature, so reading its links hands a design-less feature
  # that feature's creative. The branch fallback must therefore not outrank the
  # "identified-only" rule the spec.md recovery asks for.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  make_workspace_git "002-checkout-redesign"
  stage_spec_with_section "002-checkout-redesign" \
    "https://www.figma.com/design/OtherFEATURE/Checkout?node-id=12-345"
  export SPECIFY_FEATURE="003-redis-cache"
  run "$SCRIPT" --dry-run --input "Add a Redis cache on the billing endpoint."
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "no-figma-link" ]]
}

@test "the branch's spec.md is still a link source for the feature it names" {
  # The mirror image of the test above: with nothing else identifying the
  # feature, the branch IS the feature, and its document must keep working.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  make_workspace_git "002-checkout-redesign"
  stage_spec_with_section "002-checkout-redesign" \
    "https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345"
  unset SPECIFY_FEATURE
  run "$SCRIPT" --dry-run --input "Draft the implementation plan."
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.introspectArgs | join(" ")')" == "--file LinkFILE999 --node 12:345" ]]
}

@test "a link recovered from spec.md re-warms the per-feature cache" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  export SPECIFY_FEATURE="001-checkout"
  stage_spec_with_section "001-checkout" \
    "https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345"
  run "$SCRIPT" --input "Draft the implementation plan."
  [ "$status" -eq 0 ]
  [ -f "${WORKSPACE}/.figma/cache/links/001-checkout.json" ]
  [[ "$(jq -r '.[0].fileId' "${WORKSPACE}/.figma/cache/links/001-checkout.json")" == "LinkFILE999" ]]
}

@test "a link in this phase's input still wins over the one in spec.md" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  export SPECIFY_FEATURE="001-checkout"
  stage_spec_with_section "001-checkout" \
    "https://www.figma.com/design/OldFILE111/Checkout?node-id=1-1"
  run "$SCRIPT" --dry-run --input \
    "Redo it from https://www.figma.com/design/NewFILE222/Checkout?node-id=9-9"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.introspectArgs | join(" ")')" == "--file NewFILE222 --node 9:9" ]]
}

@test "a prototype link introspects both the viewed frame and the flow start" {
  # A prototype is a parcours: the frame the designer was on (node-id) and the
  # entry point of the flow (starting-point-node-id) are both creatives the
  # spec needs, and both come from the same batched nodes request.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --dry-run --input \
    "Build https://www.figma.com/proto/ProtoFILE1/Demo?node-id=12-345&starting-point-node-id=1%3A2"
  [ "$status" -eq 0 ]
  # Both ids ride the same batched request, so their order carries no meaning.
  [[ "$(status_json | jq -r '.introspectArgs | index("--file") as $i | .[$i + 1]')" == "ProtoFILE1" ]]
  [[ "$(status_json | jq -r '[.introspectArgs[] | select(test("^[0-9I]"))] | sort | join(",")')" == "12:345,1:2" ]]
}

# --- The per-file snapshot store --------------------------------------------
# context-snapshot.json is a single slot: the snapshot of the CURRENT run, which
# is the path every command prompt hands to the agent. One slot cannot CACHE
# across features — two features pointing at different Figma files evict each
# other, so the 'fresh' path never hits and every phase re-pays a full file +
# nodes fetch. Introspection therefore also keeps a copy keyed by file.

@test "a snapshot kept for the linked file is restored instead of re-introspecting" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  # The current slot belongs to ANOTHER feature's file, and does not cover this
  # link — on its own that forces a re-introspection.
  echo '{"fileId":"OtherFILE","pages":[]}' > "${WORKSPACE}/.figma/cache/context-snapshot.json"
  mkdir -p "${WORKSPACE}/.figma/cache/snapshots"
  echo '{"fileId":"LinkFILE999","pages":[{"id":"0:1","name":"Home","frames":[{"id":"12:345","name":"Hero","type":"FRAME"}]}],"nodes":{"nodes":{"12:345":{"document":{"type":"FRAME"}}}}}' \
    > "${WORKSPACE}/.figma/cache/snapshots/LinkFILE999.json"
  run "$SCRIPT" --input "https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
  # …and the restored snapshot became the current one, so the agent reads it.
  [[ "$(jq -r '.fileId' "${WORKSPACE}/.figma/cache/context-snapshot.json")" == "LinkFILE999" ]]
}

@test "restoring a stored snapshot keeps its age, so it still expires" {
  # Freshness is keyed on the current slot's mtime. A restore that stamps the
  # slot with "now" resurrects data past the max-age window: fetched at T0,
  # restored at T0+50, and with the 60-minute default still counted "fresh" at
  # T0+100 — an hour and forty minutes of drift handed to the agent as current.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  mkdir -p "${WORKSPACE}/.figma/cache/snapshots"
  stored="${WORKSPACE}/.figma/cache/snapshots/LinkFILE999.json"
  echo '{"fileId":"LinkFILE999","pages":[],"nodes":{"nodes":{"12:345":{"document":{"type":"FRAME"}}}}}' > "$stored"
  # The config must not out-age the snapshot, or it is stale for that reason.
  backdate_file "${WORKSPACE}/figma.projects.config.json" 90
  backdate_file "$stored" 30
  run "$SCRIPT" --input "$LINK"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
  # The republished slot carries the stored snapshot's mtime, not this run's.
  [ -z "$(find "${WORKSPACE}/.figma/cache/context-snapshot.json" -newer "$stored")" ]
}

@test "a stored snapshot that does not cover the linked node is not restored" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  mkdir -p "${WORKSPACE}/.figma/cache/snapshots"
  # Right file, but the pinned node was never deep-fetched into it.
  echo '{"fileId":"LinkFILE999","pages":[],"nodes":{"nodes":{}}}' \
    > "${WORKSPACE}/.figma/cache/snapshots/LinkFILE999.json"
  run "$SCRIPT" --dry-run --input "https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "dry-run" ]]
}

@test "a stored snapshot older than the max-age window is not restored" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  mkdir -p "${WORKSPACE}/.figma/cache/snapshots"
  stored="${WORKSPACE}/.figma/cache/snapshots/LinkFILE999.json"
  echo '{"fileId":"LinkFILE999","pages":[],"nodes":{"nodes":{"12:345":{"document":{"type":"FRAME"}}}}}' > "$stored"
  touch -t 202001010000 "$stored"
  run "$SCRIPT" --dry-run --input "https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "dry-run" ]]
}

@test "a direct link bypasses a fresh snapshot that does not cover its node" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{}' > "${WORKSPACE}/.figma/cache/context-snapshot.json"
  run "$SCRIPT" --dry-run --input \
    "https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "dry-run" ]]
}

@test "a fresh snapshot already covering the linked node stays fresh" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{"fileId":"LinkFILE999","nodes":{"nodes":{"12:345":{}}}}' \
    > "${WORKSPACE}/.figma/cache/context-snapshot.json"
  run "$SCRIPT" --dry-run --input \
    "https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
}

# --- Mandatory section integration & broad-link handling -----------------------

@test "an applicable run marks the section mandatory and renders spec/plan/tasks" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{"fileId":"LinkFILE999","nodes":{"nodes":{"12:345":{}}},"pages":[{"id":"0:1","name":"Home","frames":[{"id":"1:2","name":"Hero","type":"FRAME"}]}],"components":{},"styles":{}}' \
    > "${WORKSPACE}/.figma/cache/context-snapshot.json"
  run "$SCRIPT" --input "$LINK"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
  [[ "$(status_json | jq -r '.mustInject')" == "true" ]]
  [[ "$(status_json | jq -r '.specSection')" == *"/sections/${SPECIFY_FEATURE:-default}/spec.md" ]]
  [[ "$(status_json | jq -r '.planSection')" == *"/sections/${SPECIFY_FEATURE:-default}/plan.md" ]]
  [[ "$(status_json | jq -r '.tasksSection')" == *"/sections/${SPECIFY_FEATURE:-default}/tasks.md" ]]
  [ -f "$(section_path spec)" ]
  [ -f "$(section_path plan)" ]
  [ -f "$(section_path tasks)" ]
  grep -q "Hero" "$(section_path spec)"
}

@test "a broad link (file/page, no node-id) flags linkScope broad with candidate frames" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{"fileId":"BroadFILE","pages":[{"id":"0:1","name":"Home","frames":[{"id":"1:2","name":"Hero","type":"FRAME"},{"id":"1:3","name":"Footer","type":"FRAME"}]}]}' \
    > "${WORKSPACE}/.figma/cache/context-snapshot.json"
  run "$SCRIPT" --input "Build the home page https://www.figma.com/design/BroadFILE/Home"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
  [[ "$(status_json | jq -r '.linkScope')" == "broad" ]]
  [[ "$(status_json | jq -r '.candidateFrames | length')" == "2" ]]
  [[ "$(status_json | jq -r '.mustInject')" == "true" ]]
  grep -qi "confirm which of these frames" "$(section_path spec)"
}

@test "a link pinned to a top-level frame reports linkScope frame" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{"fileId":"PinFILE","nodes":{"nodes":{"9:9":{}}},"pages":[{"id":"0:1","name":"P","frames":[{"id":"9:9","name":"Card","type":"FRAME"}]}]}' \
    > "${WORKSPACE}/.figma/cache/context-snapshot.json"
  run "$SCRIPT" --input "https://www.figma.com/design/PinFILE/X?node-id=9-9"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
  [[ "$(status_json | jq -r '.linkScope')" == "frame" ]]
}

# --- Review fixes: stale-section cleanup & broad/frame classification ----------

@test "ensure clears stale rendered sections when Figma no longer applies" {
  # No config -> no-config skip path. A leftover .figma/cache/section.*.md from a prior
  # run must be removed so the verifier does not treat this run as 'applicable'.
  stage_section tasks stale
  stage_section spec stale
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "no-config" ]]
  [ ! -f "$(section_path tasks)" ]
  [ ! -f "$(section_path spec)" ]
}

@test "ensure preserves a prior rendered section on a transient introspect-failure" {
  # Figma APPLIES (valid config, enabled target) but introspection fails for lack
  # of a token. A prior phase's render must NOT be wiped: the verifier keys
  # 'applicable' on the file's existence, so wiping it would make after_* verify
  # report not-applicable and let a --strict CI gate silently pass for a run where
  # Figma genuinely applies. Unlike no-config, this skip is transient -> keep it.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  stage_section tasks 'prior render'
  unset FIGMA_PAT
  run "$SCRIPT" --input "$LINK"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "introspect-failed" ]]
  [ -f "$(section_path tasks)" ]
}

@test "a link to a deep-fetched node that is not a top-level frame stays pinned (linkScope frame)" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  # 50:9 is deep-fetched into .nodes.nodes but is NOT a top-level page frame.
  echo '{"fileId":"DeepFILE","nodes":{"nodes":{"50:9":{}}},"pages":[{"id":"0:1","name":"P","frames":[{"id":"1:2","name":"Hero","type":"FRAME"}]}]}' \
    > "${WORKSPACE}/.figma/cache/context-snapshot.json"
  run "$SCRIPT" --input "https://www.figma.com/design/DeepFILE/X?node-id=50-9"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
  [[ "$(status_json | jq -r '.linkScope')" == "frame" ]]
}

@test "a link whose node-id is a page/canvas is broad (covers many frames)" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  # 0:1 IS a page id in the snapshot, not a specific frame.
  echo '{"fileId":"PageFILE","nodes":{"nodes":{"0:1":{}}},"pages":[{"id":"0:1","name":"Home","frames":[{"id":"1:2","name":"Hero","type":"FRAME"},{"id":"1:3","name":"Footer","type":"FRAME"}]}]}' \
    > "${WORKSPACE}/.figma/cache/context-snapshot.json"
  run "$SCRIPT" --input "https://www.figma.com/design/PageFILE/Home?node-id=0-1"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
  [[ "$(status_json | jq -r '.linkScope')" == "broad" ]]
  [[ "$(status_json | jq -r '.candidateFrames | length')" == "2" ]]
}

# --- Copilot review: broad detection via node type (document root / canvas) ----

@test "a link to a CANVAS-type node not indexed in pages[] is broad (by node type)" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  # 7:7 is deep-fetched with type CANVAS but is NOT in .pages[].id.
  echo '{"fileId":"CanvFILE","nodes":{"nodes":{"7:7":{"document":{"type":"CANVAS"}}}},"pages":[{"id":"0:1","name":"P","frames":[{"id":"1:2","name":"Hero","type":"FRAME"}]}]}' \
    > "${WORKSPACE}/.figma/cache/context-snapshot.json"
  run "$SCRIPT" --input "https://www.figma.com/design/CanvFILE/X?node-id=7-7"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
  [[ "$(status_json | jq -r '.linkScope')" == "broad" ]]
}

@test "a link to a SECTION-type node stays pinned (linkScope frame)" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{"fileId":"SecFILE","nodes":{"nodes":{"8:8":{"document":{"type":"SECTION"}}}},"pages":[{"id":"0:1","name":"P","frames":[{"id":"1:2","name":"Hero","type":"FRAME"}]}]}' \
    > "${WORKSPACE}/.figma/cache/context-snapshot.json"
  run "$SCRIPT" --input "https://www.figma.com/design/SecFILE/X?node-id=8-8"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
  [[ "$(status_json | jq -r '.linkScope')" == "frame" ]]
}

@test "a missing jq is a skip reason, not a crash (exit 0, JSON still emitted)" {
  # The hook must never block generation, and it must never leave the agent with
  # nothing: without a status object the agent improvises — typically by calling
  # a Figma MCP server with a node id it extracted from the URL itself.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run env PATH="$(path_without_jq)" "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.ran')" == "false" ]]
  [[ "$(status_json | jq -r '.reason')" == "missing-dependency" ]]
  [[ "$(status_json | jq -r '.dependency')" == "jq" ]]
  [[ "$(status_json | jq -r '.mustInject')" == "false" ]]
}

@test "the missing-jq diagnostic names a no-sudo install path" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run env PATH="$(path_without_jq)" "$SCRIPT"
  [[ "$output" == *"jq"* ]]
  # Homebrew is not always writable; the guidance must not stop at 'brew install'.
  [[ "$output" == *"no sudo"* ]]
}

# --- Cache housekeeping ------------------------------------------------------
# The sweep (figma_gc_cache) is wired ahead of every early exit, so the runs that
# produce the most orphans — the design-less ones — are also the ones that clean
# up. 11520 minutes = 8 days, past the 7-day default retention window.

stage_orphan_links() { # $1 = feature key
  mkdir -p "${WORKSPACE}/.figma/cache/links"
  printf '[{"fileId":"F1","nodeId":"1:2"}]\n' > "${WORKSPACE}/.figma/cache/links/$1.json"
  backdate_file "${WORKSPACE}/.figma/cache/links/$1.json" 11520
}

@test "a real run sweeps orphaned cache entries, even a design-less one" {
  # no-config exits before anything else happens: the sweep still has to have run.
  stage_orphan_links "throwaway-spike"
  run "$SCRIPT" --input "Pure backend refactor."
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "no-config" ]]
  [ ! -f "${WORKSPACE}/.figma/cache/links/throwaway-spike.json" ]
}

@test "a dry run leaves the cache exactly as it found it" {
  # A rehearsal must not change what a later real run decides — the same reason
  # --dry-run does not record this phase's links.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  stage_orphan_links "throwaway-spike"
  run "$SCRIPT" --dry-run --input "$LINK"
  [ "$status" -eq 0 ]
  [ -f "${WORKSPACE}/.figma/cache/links/throwaway-spike.json" ]
  [ ! -f "${WORKSPACE}/.figma/cache/.gc-stamp" ]
}

@test "the sweep never collects the links the very same run just recorded" {
  # The links are written after the sweep, but the feature has no specs/
  # directory yet at /speckit.specify time — ownership alone would have collected
  # them on the NEXT phase, before it could inherit them.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --input "$LINK"
  [ "$status" -eq 0 ]
  links="${WORKSPACE}/.figma/cache/links/${SPECIFY_FEATURE}.json"
  [ -f "$links" ]
  backdate_file "$links" 11520
  FIGMA_CACHE_GC=force run "$SCRIPT" --input "Draft the implementation plan."
  [ "$status" -eq 0 ]
  [ -f "$links" ]
  [[ "$(status_json | jq -r '.links[0].fileId')" == "LinkFILE999" ]]
}

# -----------------------------------------------------------------------------
# Autonomous introspection (autoIntrospect) — the opt-in that lets a target
# obtain design context with no Figma link in the input.
# -----------------------------------------------------------------------------

@test "autoIntrospect defaults to off: a link-less run still ends at no-figma-link" {
  # The 2.0.0 contract is the default and must stay it. A config that says
  # nothing about autoIntrospect grants nothing.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --input "add a Redis cache on the billing endpoint"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "no-figma-link" ]]
  [[ "$(status_json | jq -r '.trigger')" == "none" ]]
  [[ "$(status_json | jq -r '.mustInject')" == "false" ]]
}

@test "on-request without --assume-design declines instead of introspecting" {
  cp "${FIXTURES_DIR}/autointrospect-on-request-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --input "build the checkout summary panel"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "auto-declined" ]]
  [[ "$(status_json | jq -r '.trigger')" == "none" ]]
  [[ "$(status_json | jq -r '.mustInject')" == "false" ]]
}

@test "on-request with --assume-design introspects the mapped file" {
  cp "${FIXTURES_DIR}/autointrospect-on-request-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --dry-run --assume-design --input "build the checkout summary panel"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "dry-run" ]]
  [[ "$(status_json | jq -r '.trigger')" == "auto" ]]
  [[ "$(status_json | jq -r '.introspectArgs | index("--file")')" != "null" ]]
  [[ "$(status_json | jq -r '.introspectArgs | index("single123FILE")')" != "null" ]]
  # No node id exists to pin: the autonomous scope is the whole file.
  [[ "$(status_json | jq -r '.introspectArgs | index("--node")')" == "null" ]]
}

@test "--assume-design grants nothing when the target keeps mode off" {
  # An agent must never be able to authorise itself: the authorisation lives in
  # the committed config, which is reviewable in a PR.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --dry-run --assume-design --input "build the checkout summary panel"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "no-figma-link" ]]
  [[ "$output" == *"autoIntrospect.mode='off'"* ]]
}

@test "mode always introspects a link-less run without any flag" {
  cp "${FIXTURES_DIR}/autointrospect-always-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --dry-run --input "build the checkout summary panel"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "dry-run" ]]
  [[ "$(status_json | jq -r '.trigger')" == "auto" ]]
}

@test "a pasted link still wins over an always-on autoIntrospect target" {
  cp "${FIXTURES_DIR}/autointrospect-always-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --dry-run --input "$LINK"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.trigger')" == "link" ]]
  # The linked file overrides the mapped one, exactly as before.
  [[ "$(status_json | jq -r '.introspectArgs | index("LinkFILE999")')" != "null" ]]
  [[ "$(status_json | jq -r '.introspectArgs | index("single123FILE")')" == "null" ]]
}

@test "an autonomous run invents no link and remembers none" {
  # The rendered section must report "context derived from page mapping", never a
  # link the developer did not paste — and the per-feature memory, which later
  # phases inherit, must not be seeded with a fabricated one either.
  cp "${FIXTURES_DIR}/autointrospect-always-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{"fileId":"single123FILE","pages":[{"id":"0:1","name":"Checkout","frames":[{"id":"12:345","name":"Summary","type":"FRAME"}]}]}' \
    > "${WORKSPACE}/.figma/cache/context-snapshot.json"
  run "$SCRIPT" --input "build the checkout summary panel"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
  [[ "$(status_json | jq -r '.links | length')" == "0" ]]
  [ ! -f "${WORKSPACE}/.figma/cache/links/${SPECIFY_FEATURE}.json" ]
}

@test "an autonomous run is broad, so the creative checkpoint fires by construction" {
  # No node id pins the creative, so design rule 5 (confirm the frame) must apply
  # without a code path of its own.
  cp "${FIXTURES_DIR}/autointrospect-always-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{"fileId":"single123FILE","pages":[{"id":"0:1","name":"Checkout","frames":[{"id":"12:345","name":"Summary","type":"FRAME"}]}]}' \
    > "${WORKSPACE}/.figma/cache/context-snapshot.json"
  run "$SCRIPT" --input "build the checkout summary panel"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.linkScope')" == "broad" ]]
  [[ "$(status_json | jq -r '.candidateFrames | length')" == "1" ]]
  [[ "$(status_json | jq -r '.confirmFrames')" == "true" ]]
  [[ "$(status_json | jq -r '.mustInject')" == "true" ]]
}

@test "a file over maxFrames refuses the autonomous path and asks for a node id" {
  # maxFrames = 3 in the fixture; the snapshot holds 4 top-level frames.
  cp "${FIXTURES_DIR}/autointrospect-always-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{"fileId":"single123FILE","pages":[{"id":"0:1","name":"Checkout","frames":[{"id":"1:1","name":"A"},{"id":"1:2","name":"B"},{"id":"1:3","name":"C"},{"id":"1:4","name":"D"}]}]}' \
    > "${WORKSPACE}/.figma/cache/context-snapshot.json"
  run "$SCRIPT" --input "build the checkout summary panel"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "too-large-for-auto" ]]
  [[ "$(status_json | jq -r '.mustInject')" == "false" ]]
  [[ "$(status_json | jq -r '.specSection')" == "null" ]]
  [[ "$output" == *"maxFrames"* ]]
}

@test "the frame budget never applies to a link-driven run" {
  # The node id already pins the creative, so a wide file is not a problem there.
  cp "${FIXTURES_DIR}/autointrospect-always-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{"fileId":"LinkFILE999","pages":[{"id":"0:1","name":"Checkout","frames":[{"id":"1:1","name":"A"},{"id":"1:2","name":"B"},{"id":"1:3","name":"C"},{"id":"1:4","name":"D"}]}],"nodes":{"nodes":{"12:345":{"document":{"type":"FRAME"}}}}}' \
    > "${WORKSPACE}/.figma/cache/context-snapshot.json"
  run "$SCRIPT" --input "$LINK"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
  [[ "$(status_json | jq -r '.trigger')" == "link" ]]
}

@test "autoIntrospect without figmaFileId reports auto-unavailable, not a crawl" {
  # A project/team id would walk every file of an organisation — that is
  # /speckit.figma.introspect's job, never an automatic pre-generation hook's.
  cp "${FIXTURES_DIR}/autointrospect-no-file.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --dry-run --input "build the checkout summary panel"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "auto-unavailable" ]]
  [[ "$output" == *"figmaFileId"* ]]
}

# -----------------------------------------------------------------------------
# oversized link scope — a pinned node id is not automatically a creative.
# -----------------------------------------------------------------------------

@test "a page-sized pinned frame is oversized, not a confirmed creative" {
  # The R1 failure: a link copied from a full-page desktop frame pins a FRAME
  # like any other, so it looked exact while covering the whole page.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  cat > "${WORKSPACE}/.figma/cache/context-snapshot.json" <<'JSON'
{"fileId":"LinkFILE999","pages":[{"id":"0:1","name":"Desktop","frames":[{"id":"12:345","name":"Landing","type":"FRAME"}]}],
 "nodes":{"nodes":{"12:345":{"document":{"id":"12:345","name":"Landing page","type":"FRAME",
  "absoluteBoundingBox":{"width":1440,"height":12000},
  "children":[{"id":"12:400","name":"Hero"},{"id":"12:500","name":"Pricing"}]}}}}}
JSON
  run "$SCRIPT" --input "$LINK"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.linkScope')" == "oversized" ]]
  # The candidates are the node's OWN children: the developer linked the right
  # page, they only have to say which block of it.
  [[ "$(status_json | jq -r '[.candidateFrames[].name] | join(",")')" == "Hero,Pricing" ]]
}

@test "a component-sized pinned frame stays a confirmed creative" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  cat > "${WORKSPACE}/.figma/cache/context-snapshot.json" <<'JSON'
{"fileId":"LinkFILE999","pages":[{"id":"0:1","name":"D","frames":[{"id":"12:345","name":"Card","type":"FRAME"}]}],
 "nodes":{"nodes":{"12:345":{"document":{"id":"12:345","name":"Card","type":"FRAME",
  "absoluteBoundingBox":{"width":360,"height":240},"children":[{"id":"12:400","name":"Title"}]}}}}}
JSON
  run "$SCRIPT" --input "$LINK"
  [[ "$(status_json | jq -r '.linkScope')" == "frame" ]]
}

@test "a node with too many descendants is oversized even when it is short" {
  # Height is not the only way to be page-sized; a dense frame is just as wide a
  # context to reason over.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  children="$(jq -nc '[range(0;60) | {id: ("9:\(.)"), name: "n\(.)", children: [{id: "8:\(.)", name: "d\(.)"}, {id: "7:\(.)", name: "e\(.)"}]}]')"
  jq -nc --argjson c "$children" '{fileId:"LinkFILE999",pages:[],
    nodes:{nodes:{"12:345":{document:{id:"12:345",name:"Dense",type:"FRAME",
    absoluteBoundingBox:{width:1440,height:900},children:$c}}}}}' \
    > "${WORKSPACE}/.figma/cache/context-snapshot.json"
  run "$SCRIPT" --input "$LINK"
  [[ "$(status_json | jq -r '.linkScope')" == "oversized" ]]
}

@test "the oversized thresholds are overridable per project" {
  # "Page-sized" is a property of the design system in use, not a constant.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  cat > "${WORKSPACE}/.figma/cache/context-snapshot.json" <<'JSON'
{"fileId":"LinkFILE999","pages":[],
 "nodes":{"nodes":{"12:345":{"document":{"id":"12:345","name":"Tall","type":"FRAME",
  "absoluteBoundingBox":{"width":1440,"height":5000},"children":[{"id":"12:400","name":"A"}]}}}}}
JSON
  run "$SCRIPT" --input "$LINK"
  [[ "$(status_json | jq -r '.linkScope')" == "oversized" ]]
  FIGMA_OVERSIZED_HEIGHT=9000 run "$SCRIPT" --input "$LINK"
  [[ "$(status_json | jq -r '.linkScope')" == "frame" ]]
}
