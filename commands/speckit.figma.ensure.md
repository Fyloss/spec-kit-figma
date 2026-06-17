---
description: Automatically refresh the Figma design context before spec/tasks generation. Invoked by the extension's before_specify/before_tasks hooks — the developer never runs it by hand. Safe no-op when Figma does not apply to the run.
---

# /speckit.figma.ensure — Automatic Figma design context

You are the design-context bootstrap. This command is invoked automatically by
the extension hooks (`before_specify` / `before_tasks`) — do NOT ask the
developer for approval: the underlying script is a safe no-op whenever Figma
does not apply, and it never blocks spec/tasks generation.

## 1. Refresh the snapshot

From the workspace root, run `./.specify/scripts/bash/figma-ensure-context.sh`,
piping the user's RAW feature input (description, arguments, any pasted links —
verbatim) via `--input -`. Pass the target package name as the first argument
in mono-/multi-repo workspaces:

```bash
./.specify/scripts/bash/figma-ensure-context.sh --input - <<'SPECKIT_FIGMA_INPUT'
<the user's verbatim feature input>
SPECKIT_FIGMA_INPUT
```

Any direct Figma link in the input is detected and introspected automatically —
the linked file/frames become the authoritative design targets (node-level
detail included), so no manual `/speckit.figma.introspect` run is needed. The
script skips harmlessly when the extension is not configured, the target is
excluded, or `.figma-context-snapshot.json` is already fresh and covers the
linked nodes.

## 2. Interpret the status JSON

- `"ran": true` or `"reason": "fresh"` — load `.figma-context-snapshot.json`
  and apply the rules of `/speckit.figma.introspect` (sections 3-7: frame
  confirmation, component placement, token gaps, tests + Storybook sub-tasks)
  to the Figma-relevant parts of your output. Treat any `links` reported in
  the status JSON as authoritative design targets for the affected components.
- Any other `reason` (`no-config`, `unresolved-placeholders`, `target-excluded`,
  `target-not-mapped`, `target-disabled`, `ambiguous-target`, `invalid-config`,
  `introspect-failed`) — proceed without Figma context and add a short note
  mentioning the reason. Never block generation.

## 3. Credentials hygiene

Never read, print or echo the Figma token (`FIGMA_PAT`, keychain).
The scripts load it internally; you only ever need their JSON output.
