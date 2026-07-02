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
| Component | Placement | Level | Justification | Mobile frame | Desktop frame |
|-----------|-----------|-------|---------------|--------------|---------------|
| {{NAME}} | {{DS | lib | app}} | {{reuse | create-ds | create-app}} | {{WHY}} | {{LINK}} | {{LINK}} |

> Creative confirmation: {{confirmed | pending}} — developer to validate the mobile/desktop links above.

### Responsiveness
- Mobile-first. Tablet behavior: {{from tablet frame | interpolated from mobile+desktop}}.
  Even without a tablet mockup, the implementation MUST be tablet-responsive.

### Design token mapping
| Figma value | Property | DS token | Status |
|-------------|----------|----------|--------|
| {{VALUE}} | {{color | spacing | typography | radius | shadow}} | {{TOKEN | none}} | {{mapped | raw-candidate}} |

### Design System Token Gaps
<!-- Figma tokens with no DS equivalent. DS update is triggered via CI, not by the agent. -->
| Figma value | Nearest DS token | Affected component | DS update? |
|-------------|------------------|--------------------|------------|
| {{VALUE}} | {{TOKEN | none}} | {{COMPONENT}} | {{requested | declined}} |

> DS update mechanism via CI pipeline: **[NEEDS VERIFICATION]**.

### Warnings & drift
{{#each WARNINGS}}- ⚠️ {{message}}{{/each}}
