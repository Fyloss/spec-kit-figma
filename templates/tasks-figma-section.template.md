<!--
  tasks-figma-section.template.md
  Injected into tasks.md. Each component yields a placement task plus the
  mandatory tests sub-task (and a component-catalog sub-task when the project uses
  one) for UI components.
  No Design System configured? `create-ds` and the token-gap sub-task do not
  apply — components go to the app or a shared lib, tokens map to the project's
  own source (or stay raw).
-->

## Figma-derived tasks *(extension: figma)*

### {{COMPONENT_NAME}} — {{reuse | create-ds | create-app | create-lib}}
- **Placement justification**: {{WHY}} (level: {{1 reuse | 2 create-ds | 3 create-app/lib}})
- **Design references**: {{FRAME_LINKS}} (one per provided breakpoint)
- **Responsive**: breakpoints {{LIST_PROVIDED_BREAKPOINTS}}; policy {{from overlay/constitution | none declared}}.
- **Tokens**: {{TOKEN_LIST}} ({{mapped | raw-candidate}})

- [ ] T-{{n}}: Implement / reuse `{{COMPONENT_NAME}}` at `{{TARGET_PATH}}`
- [ ] T-{{n}}: Add/update automated tests for `{{COMPONENT_NAME}}` (unit + interaction)   <!-- required for every UI component -->
{{#if COMPONENT_CATALOG}}- [ ] T-{{n}}: Create/update {{CATALOG_NAME}} entry for `{{COMPONENT_NAME}}`   <!-- when the project uses a component catalog, e.g. Storybook -->{{/if}}
{{#if INTERPOLATED_BREAKPOINT}}- [ ] T-{{n}}: Verify responsive behaviour for {{INTERPOLATED_BREAKPOINT}} (interpolated — policy-driven){{/if}}
{{#if SHARED}}- [ ] T-{{n}}: Wire shared component into: {{SHARED_ACROSS}} (single source, no duplication){{/if}}
{{#if TOKEN_GAP}}- [ ] T-{{n}}: Open DS token-gap request for {{VALUE}} → DS update via the project's process ({{overlay/constitution}}); agent never edits the DS directly{{/if}}
{{#if AMBIGUOUS}}- [ ] T-{{n}}: ⚠️ Awaiting developer decision on placement — reason: {{DOUBT_CAUSE}}{{/if}}
