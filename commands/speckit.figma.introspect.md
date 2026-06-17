---
description: Autonomously introspect the mapped Figma pages for the target package and produce design-grounded context for spec/plan/tasks. Honors the Design System rules, responsive requirements, shared-mockup handling, token-gap detection and human confirmation checkpoints.
---

# /speckit.figma.introspect — Autonomous Figma introspection

You are the design-context agent. Operate autonomously across the mapped pages,
but respect the explicit human-confirmation checkpoints below. Always load and
obey `./.specify/memory/figma-design-rules.md` (or `./memory/figma-design-rules.md`
when running from the extension checkout).

> **Automatic invocation:** the extension hooks (`before_specify` /
> `before_tasks`) invoke `/speckit.figma.ensure`, which runs
> `figma-ensure-context.sh` with the feature input piped in via `--input -`,
> so a fresh snapshot is usually already present — **including node-level
> detail for any direct Figma links pasted in the feature input**, which the
> hook parses and introspects on its own. (Agents without extension-hook
> support can opt into prompt injection with `install.sh --prompt-hooks`.)
> Run this command manually for deep dives (specific nodes, custom depth,
> team/project exploration) or to force a refresh.

## Scripts

Run these from the workspace root. The short names used below map to:

- `detect` → `./.specify/scripts/bash/figma-detect-target.sh`
- `parse` → `./.specify/scripts/bash/figma-parse-links.sh`
- `resolve` → `./.specify/scripts/bash/figma-resolve-source.sh`
- `introspect` → `./.specify/scripts/bash/figma-introspect.sh`
- `ensure` → `./.specify/scripts/bash/figma-ensure-context.sh` (auto pre-specify/tasks
  hook: introspects only when the snapshot is missing or stale; safe no-op
  otherwise)

## 0. Inputs & direct Figma links

- First, scan the user-provided input for direct Figma links. Run the `parse`
  script over the input. For every detected `{fileId, nodeId}`, treat it as an
  **authoritative design target**: use it directly (via `introspect --file <id>
  --node <nodeId>`) instead of, or in addition to, the page mapping. Direct links
  always take precedence over config mapping for the components they reference.

## 1. Gate

- Resolve the feature's target package, then run `detect`. If `enabled` is
  `false` (excluded / not-mapped / disabled), **skip Figma entirely** and note it.
- If a `figmaFileId` is a `REPLACE_WITH_*` placeholder, stop with a blocking error.

## 1b. Select the design-context engine (REST default, optional MCP)

- Run the `resolve` script. It returns the **effective** engine for this run:
  - `effective: "rest"` — use the portable REST engine: drive `introspect` (curl +
    jq) and reason over the resulting `.figma-context-snapshot.json`. This is the
    default and the only engine guaranteed in CI.
  - `effective: "mcp"` — a Figma **MCP server** is configured and reachable. Prefer
    its richer tools (e.g. code/variables/screenshot retrieval) for design context,
    using the `mcp.url` / `serverName` from the config. Still run `introspect` to
    refresh the local snapshot as a portable baseline.
- **Fallback is automatic:** when `contextSource: "mcp"` but the MCP server is
  unreachable, `resolve` reports `fellBack: true` and `effective: "rest"`. Proceed
  with REST and surface a short, non-blocking note. Only treat an unreachable MCP
  server as a hard error when `mcp.fallbackToRest` is `false` (the script exits
  non-zero and `effective` is `null`).
- Never assume MCP is present: portability (REST) is the contract; MCP is an
  opt-in enrichment for those who run the server.

## 2. Autonomous traversal

- Resolve the design source for the target from the strongest signal available
  (an explicit direct link always wins), then walk the Figma hierarchy
  **organization > team > project > file > page > frame** without per-step human
  approval:
  - `figmaTeamId` / `figmaTeamIds` set → run `introspect --team <teamId>` (repeat
    `--team` for each id). The script enumerates **every project of each team**,
    then **every file of each project**, writing a nested `teams[] → projects[] →
    files[]` index into `.figma-context-snapshot.json`. Use it to autonomously
    pick the relevant files, then drill into their pages.
  - `figmaProjectId` set → run `introspect --project <projectId>` to enumerate all
    files of that single project.
  - `figmaFileId` set → run `introspect --file <fileId>` to introspect one file.
  - The agent MUST be able to walk the whole team/project/file tree from a single
    team or project id; it never asks the developer to approve each page.
- When a team or project enumeration surfaces several files, select the file(s)
  relevant to the feature (e.g. by name and by `pageToPackageMapping`), then
  re-run `introspect --file <id>` on each to extract its pages.
- Restrict extraction to pages declared in `pageToPackageMapping`. Ignore
  unmapped pages.
- Extract design detail to the depth the feature needs. At the default
  `--depth 2` the snapshot indexes pages, top-level frames and the file's
  component/style metadata (`components`, `componentSets`, `styles`). For
  nested layers, component instances, variant properties and layout constraints
  (auto-layout direction, padding, gap), re-run `introspect --file <id>
  --depth <N>` with a deeper tree and/or `introspect --file <id> --node
  <nodeId>` for each frame of interest — the raw node JSON (fills, typography,
  spacing, radius, shadows) lands in the snapshot's `nodes` field. Reuse the
  cached `.figma-context-snapshot.json` within the session; rely on the
  script's backoff for HTTP 429.

## 3. Creative identification checkpoint (mobile + desktop)

- For each component, identify the candidate **mobile** and **desktop** frames you
  believe correspond to it. Before producing tasks from them, send the developer
  the Figma deep links for both and ask them to confirm you targeted the right
  creative. Proceed once confirmed; if the developer corrects you, re-introspect
  the corrected node.
- The project is **mobile-first**. Even when no tablet frame exists, the resulting
  implementation MUST be responsive on tablet breakpoints — interpolate the tablet
  layout from the mobile and desktop frames and state this explicitly.

## 4. Component placement (3-level resolution)

For every component, decide placement and record an explicit justification:

1. **Reuse** — query the Design System file/inventory (`designSystem`). If an
   equivalent exists, generate a *reuse* task. Never duplicate it.
2. **Create in Design System** — only if the component is **purely presentational
   (no business logic, no data fetching, no routing, no domain state)** AND is used
   across multiple apps. If business logic is present, it MUST NOT go to the DS.
3. **Create in app / shared lib** — app-specific → app package; shared logic →
   domain lib.

- **Shared mockups:** when a page is `shared: true` / `sharedAcross` lists several
  apps (e.g. a product detail page add-to-cart, or a header with the user account icon shared by
  several apps), route the component once to the shared location (DS if pure UI,
  else shared lib) and reference it from each consuming app — never duplicate.
- **Doubt about the level:** if you are unsure where a component belongs, **ask the
  developer**, explaining precisely what is causing the doubt (e.g. "this card
  contains a price-formatting rule, which looks like business logic → DS is not
  allowed; should it go to lib-cart-domain or stay app-local?"). This is the
  `ambiguous` → `ask` path. If the developer skips, continue without Figma context
  for that component and surface a visible warning in the spec and the task.

## 5. Token-gap detection

- When mapping extracted Figma values to Design System tokens, if a value has no
  matching DS token (a **token gap**), do not silently invent one:
  - Record the gap in the spec under a **"Design System Token Gaps"** section
    (Figma value, nearest DS token if any, affected component).
  - Ask whether the Design System should be updated. The DS update itself MUST be
    triggered via CI (a pipeline job), not performed directly by the agent.
    > NOTE: the exact CI trigger mechanism is **[NEEDS VERIFICATION]** — flag it.
  - Until resolved, output the raw value flagged as a tokenization candidate.

## 6. UI component changes → tests + Storybook

- Whenever a task creates or modifies a UI component, it MUST also:
  - add or update automated tests (unit/interaction) for that component, and
  - create or update the corresponding **Storybook** story.
- Emit these as explicit sub-tasks; a UI change without tests + Storybook is
  considered incomplete.

## 7. Output

Produce a design-context block (using `templates/spec-figma-section.template.md` and
`templates/tasks-figma-section.template.md`) containing: introspected pages, per-component
placement + justification, mobile/desktop frame links, tablet-responsive note,
token mappings, token gaps, and the required tests/Storybook sub-tasks.
