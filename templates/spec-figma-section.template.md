<!--
  spec-figma-section.template.md
  Injected into spec.md when the Figma extension is active for the feature's target.
  Replace every {{PLACEHOLDER}}. Remove sections that do not apply.
-->

## Figma Design Context *(extension: figma)*

- **Mode**: {{single-repo | mono-repo | multi-repo}}
- **Target package**: {{TARGET_PACKAGE}}  ·  **Role**: {{design-system | app-host | app | lib}}
- **Figma file**: `{{FIGMA_FILE_ID}}`  ·  **Project**: `{{FIGMA_PROJECT_ID | n/a}}`
- **Snapshot**: `.figma/cache/context-snapshot.json` @ {{GENERATED_AT}}  ·  Figma `lastModified`: {{LAST_MODIFIED}}

### Direct links provided in input
{{#each DIRECT_LINKS}}- [{{url}}] → file `{{fileId}}`, node `{{nodeId}}`{{/each}}
<!-- If none: "None — context derived from page mapping." -->

### Introspected pages (mapped only)
| Page | Target package | Shared across |
|------|----------------|---------------|
| {{PAGE_NAME}} | {{TARGET_PACKAGE}} | {{SHARED_ACROSS | -}} |

### Components & placement
| Component | Placement | Level | Justification | Frames (per breakpoint) |
|-----------|-----------|-------|---------------|-------------------------|
| {{NAME}} | {{DS | lib | app}} | {{reuse | create-ds | create-app}} | {{WHY}} | {{LINKS}} |

> No Design System configured? `DS` / `create-ds` does not apply — route to the app or a shared lib.

> Creative confirmation: {{confirmed | pending}} — developer to validate the frame links above.

### Responsiveness
- Breakpoints provided by the design: {{LIST_PROVIDED_BREAKPOINTS}}.
- Responsive policy: {{from project overlay/constitution | none declared — cover provided breakpoints only}}.
  {{If interpolating an absent breakpoint, name it and state the interpolation explicitly.}}

### Design token mapping
| Figma value | Property | Token (DS / theme / CSS var) | Status |
|-------------|----------|------------------------------|--------|
| {{VALUE}} | {{color | spacing | typography | radius | shadow}} | {{TOKEN | none}} | {{mapped | raw-candidate}} |

{{#if DESIGN_SYSTEM}}
### Design System Token Gaps
<!-- Only when a Design System is configured. Figma tokens with no DS equivalent; the agent never edits the DS directly (any update follows the project's own process, overlay/constitution). With no DS, omit this section entirely — raw values are the norm, not gaps. -->
| Figma value | Nearest DS token | Affected component | DS update? |
|-------------|------------------|--------------------|------------|
| {{VALUE}} | {{TOKEN | none}} | {{COMPONENT}} | {{requested | declined}} |

> DS update process: {{from project overlay/constitution | to be defined by the DS owner}} — the agent never edits the DS directly.
{{/if}}

### Warnings & drift
{{#each WARNINGS}}- ⚠️ {{message}}{{/each}}
