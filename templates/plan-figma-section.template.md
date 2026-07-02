<!--
  plan-figma-section.template.md
  Injected into plan.md when the Figma extension is active for the feature's target.
  Replace every {{PLACEHOLDER}}. Remove sections that do not apply.
  The deterministic facts (file, pages, frames, links) are auto-filled by
  figma-render-section.sh below this template; complete the judgement fields here.
-->

## Figma Design Plan *(extension: figma)*

- **Mode**: {{single-repo | mono-repo | multi-repo}}
- **Figma file**: `{{FIGMA_FILE_ID}}`  ·  **Project**: `{{FIGMA_PROJECT_ID | n/a}}`
- **Design-context engine**: {{rest | mcp}} (REST is the portable baseline; MCP, when reachable, yields more faithful implementation)
- **Snapshot**: `.figma/cache/context-snapshot.json` @ {{GENERATED_AT}}  ·  Figma `lastModified`: {{LAST_MODIFIED}}

### Component strategy (3-level resolution)
For every UI element the feature touches, the plan MUST state the target location
and why. When a Design System is configured, apply the DS purity rule (DS = purely
presentational); when none is configured, the resolution collapses to *reuse → app
/ lib* and `create-ds` does not apply.

| Component | Decision | Level | Target path | Justification |
|-----------|----------|-------|-------------|---------------|
| {{NAME}} | {{reuse | create-ds | create-app | create-lib}} | {{1 | 2 | 3}} | {{PATH}} | {{WHY}} |

> Shared frames (`sharedAcross`) are implemented **once** in a shared location
> (DS if pure UI, else shared lib) and consumed by each app — never duplicated.

### Responsiveness strategy
- Breakpoints provided by the design: {{LIST_PROVIDED_BREAKPOINTS}}.
- Responsive policy: {{from project overlay/constitution | none declared — cover provided breakpoints only}}.
  If a policy requires an absent breakpoint, name it and state the interpolation here.

### Design tokens & gaps
- Token mapping approach: {{map to DS / theme / CSS-var tokens | raw candidates flagged}}.
- **With a Design System:** token gaps (Figma value with no DS token) are recorded in
  the spec; the agent never edits the DS directly — any update follows the project's
  own process ({{overlay/constitution: CI pipeline | DS-owner review | …}}).
- **Without a Design System:** there are no gaps — map to the project's `tokenSource`
  or keep raw values; do not open a token-gaps section.

### Required engineering gates (UI changes)
- Every UI component created/modified MUST ship **automated tests**. When the project
  maintains a component catalog (e.g. Storybook), it MUST also ship the matching
  entry. The task breakdown enforces these as explicit sub-tasks.

### Open confirmations (human-in-the-loop)
{{#each PENDING}}- ⏳ {{message}}{{/each}}
<!-- e.g. creative confirmation for a broad Figma link, or an ambiguous placement decision. -->
