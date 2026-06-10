<!--
  tasks-figma-section.template.md
  Injected into tasks.md. Each component yields a placement task plus the
  mandatory tests + Storybook sub-tasks when it is a UI component.
-->

## Figma-derived tasks *(extension: figma)*

### {{COMPONENT_NAME}} — {{reuse | create-ds | create-app | create-lib}}
- **Placement justification**: {{WHY}} (level: {{1 reuse | 2 create-ds | 3 create-app}})
- **Design references**: mobile `{{MOBILE_LINK}}`, desktop `{{DESKTOP_LINK}}`
- **Responsive**: mobile-first; tablet {{from frame | interpolated}} — must pass tablet breakpoints.
- **Tokens**: {{TOKEN_LIST}} ({{mapped | raw-candidate}})

- [ ] T-{{n}}: Implement / reuse `{{COMPONENT_NAME}}` at `{{TARGET_PATH}}`
- [ ] T-{{n}}: Add/update automated tests for `{{COMPONENT_NAME}}` (unit + interaction)   <!-- required for UI components -->
- [ ] T-{{n}}: Create/update Storybook story for `{{COMPONENT_NAME}}`                      <!-- required for UI components -->
- [ ] T-{{n}}: Verify tablet responsiveness ({{interpolated layout}})
{{#if SHARED}}- [ ] T-{{n}}: Wire shared component into: {{SHARED_ACROSS}} (single source, no duplication){{/if}}
{{#if TOKEN_GAP}}- [ ] T-{{n}}: Open DS token-gap request for {{VALUE}} → trigger DS update via CI **[NEEDS VERIFICATION]**{{/if}}
{{#if AMBIGUOUS}}- [ ] T-{{n}}: ⚠️ Awaiting developer decision on placement — reason: {{DOUBT_CAUSE}}{{/if}}
