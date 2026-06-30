<!--
  plan-figma-section.template.md
  Injected into plan.md when the Figma extension is active for the feature's target.
  Replace every {{PLACEHOLDER}}. Remove sections that do not apply.
  The deterministic facts (file, pages, frames, links) are auto-filled by
  figma-render-section.sh below this template; complete the judgement fields here.
-->

## Figma Design Plan *(extension: figma)*

- **Mode**: {{multi-repo | mono-repo}}
- **Figma file**: `{{FIGMA_FILE_ID}}`  ·  **Project**: `{{FIGMA_PROJECT_ID | n/a}}`
- **Design-context engine**: {{rest | mcp}} (REST is the portable baseline; MCP, when reachable, yields more faithful implementation)
- **Snapshot**: `.figma/context-snapshot.json` @ {{GENERATED_AT}}  ·  Figma `lastModified`: {{LAST_MODIFIED}}

### Component strategy (3-level resolution)
For every UI element the feature touches, the plan MUST state the target location
and why, applying the Design System purity rule (DS = purely presentational):

| Component | Decision | Level | Target path | Justification |
|-----------|----------|-------|-------------|---------------|
| {{NAME}} | {{reuse | create-ds | create-app | create-lib}} | {{1 | 2 | 3}} | {{PATH}} | {{WHY}} |

> Shared frames (`sharedAcross`) are implemented **once** in a shared location
> (DS if pure UI, else shared lib) and consumed by each app — never duplicated.

### Responsiveness strategy
- Mobile-first. Tablet behavior: {{from tablet frame | interpolated from mobile+desktop}}.
  Even without a tablet mockup, the implementation MUST be tablet-responsive — state
  the interpolation here.

### Design tokens & gaps
- Token mapping approach: {{map to existing DS tokens | raw candidates flagged}}.
- Token gaps (Figma value with no DS token) are recorded in the spec and the DS
  update is triggered via **CI**, not by the agent. CI trigger: **[NEEDS VERIFICATION]**.

### Required engineering gates (UI changes)
- Every UI component created/modified MUST ship **automated tests** + a **Storybook**
  story. The task breakdown enforces these as explicit sub-tasks.

### Open confirmations (human-in-the-loop)
{{#each PENDING}}- ⏳ {{message}}{{/each}}
<!-- e.g. creative confirmation for a broad Figma link, or an ambiguous placement decision. -->
