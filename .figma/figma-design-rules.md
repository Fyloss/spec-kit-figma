# Figma Extension — Design Rules (agent memory)

These rules are non-negotiable constraints the agent MUST apply during spec, plan,
task and implementation generation whenever the Figma extension is active. They
complement the project constitution; on conflict, the stricter rule wins.

## 1. Design System purity
- A component created in the Design System MUST be **purely presentational**:
  no business logic, no data fetching, no routing, no domain/application state,
  no environment-specific code.
- If a candidate component carries any business logic, it MUST NOT be created in
  the Design System. Route it to a domain lib (if shared) or the app (if local).

## 2. Component placement (3-level resolution)
1. **Reuse** an existing Design System component when an equivalent exists.
2. **Create in Design System** only when pure UI AND reused across multiple apps.
3. **Create in app / shared lib** otherwise (app-specific → app; shared logic → lib).
- When uncertain about the level, **ask the developer** and explain the cause of
  the doubt. Never guess silently on placement.

## 3. Shared mockups
- Frames shared across several apps (e.g. product detail page add-to-cart, header with user account
  icon shared by several apps) are implemented **once** in a shared location and
  consumed by each app. Never duplicate a shared frame per app.

## 4. Responsive by default (mobile-first)
- The project is mobile-first. Apps MUST be responsive on **tablet** breakpoints
  too, **even when no tablet mockup exists**. Interpolate the tablet layout from
  the mobile and desktop frames and state the interpolation explicitly.

## 5. Creative confirmation checkpoint
- During autonomous introspection, when the agent selects candidate **mobile** and
  **desktop** frames for a component, it MUST send the developer the Figma deep
  links and obtain confirmation it targeted the correct creative before generating
  tasks from them.
- **Broad/ambiguous design links** (a file or page link covering several frames,
  with no specific frame pinned) MUST trigger frame **enumeration + confirmation**,
  never a silent skip: list the candidate top-level frames and ask which the
  feature targets. Writing "the creative was not explicitly indicated" and moving
  on is forbidden while candidate frames exist and the developer has not answered.

## 6. Design token mapping & gaps
- Map extracted Figma values to existing Design System tokens when a match exists;
  otherwise output the raw value flagged as a tokenization candidate.
- On a **token gap** (Figma token absent from the Design System), record it in the
  spec ("Design System Token Gaps"), ask whether the DS should be updated, and note
  that the DS update is triggered via **CI** (pipeline), not by the agent directly.
  The exact CI trigger is **[NEEDS VERIFICATION]**.

## 7. UI changes require tests + Storybook
- Any task that creates or modifies a UI component MUST also add/update automated
  tests and create/maintain the corresponding **Storybook** story. A UI change
  without both is incomplete.

## 8. Credentials & secrets
- The Figma access token is NEVER stored in `figma.projects.config.json` or any
  committed file, nor in any workspace file. Local: read-only PAT in the OS
  keychain, fetched via `FIGMA_PAT_COMMAND` (no `.env`; see docs/CREDENTIALS.md).
  CI / GitHub Cloud Agent: platform secret store (`credentials.source: "ci-secret"`).
- The agent MUST NOT read, print or echo the token from ANY source (environment
  variables, keychain commands). The `figma-*.sh` scripts load it internally and
  never output it; the agent only ever consumes their JSON.
- Apply least privilege: read-only Figma scopes only. Scopes scale with the
  introspection level — a single file needs `file_content:read` +
  `file_metadata:read`; project/team enumeration (`figmaProjectId` /
  `figmaTeamId(s)`, the org-level granularity) **additionally needs `projects:read`**
  (see docs/CREDENTIALS.md). A `403`/`404` on `/teams` or `/projects` endpoints
  means the PAT lacks `projects:read` or is not a team member.

## 9. Autonomy boundaries
- Autonomous: page traversal, frame/token extraction, reuse lookup, mapping.
- Human-in-the-loop (pause and ask): creative confirmation (rule 5), ambiguous
  placement (rule 2), token-gap DS update (rule 6).

## 10. Design-context engine (REST default, optional MCP)
- The **REST** engine (`contextSource: "rest"`) is the default and the portability
  contract: it MUST work everywhere, including CI, using only curl + jq.
- The **MCP** engine (`contextSource: "mcp"`) is an opt-in enrichment for users who
  run a Figma MCP server. When selected AND reachable, prefer its richer tools; it
  does NOT replace the portable REST baseline snapshot.
- Fallback is mandatory and automatic: if the MCP server is unreachable, degrade to
  REST (unless `mcp.fallbackToRest: false`, where an unreachable server is a hard
  error). Resolve the effective engine with `figma-resolve-source.sh`; never assume
  MCP is available.

## 11. Mandatory section integration (model-agnostic)
- Whenever Figma applies to a run (the `ensure` status reports `"mustInject": true`,
  i.e. `ran` or `fresh`), the Figma design section is **mandatory** in the generated
  `spec.md`, `plan.md` and `tasks.md` — regardless of the agent model.
- The section is produced deterministically by `figma-render-section.sh` (paths in
  `specSection` / `planSection` / `tasksSection`): **paste the rendered block
  verbatim**, then complete only the judgement fields (placement, justification,
  token mapping). Omitting the section is a defect, not a stylistic choice.
