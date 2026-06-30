---
description: Automatically refresh the Figma design context before spec/plan/tasks generation. Invoked by the extension's before_specify/before_plan/before_tasks hooks — the developer never runs it by hand. Safe no-op when Figma does not apply to the run.
---

# /speckit.figma.ensure — Automatic Figma design context

You are the design-context bootstrap. This command is invoked automatically by
the extension hooks (`before_specify` / `before_plan` / `before_tasks`) — do NOT
ask the developer for approval: the underlying script is a safe no-op whenever
Figma does not apply, and it never blocks spec/plan/tasks generation.

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
excluded, or `.figma/context-snapshot.json` is already fresh and covers the
linked nodes.

## 2. Integrate the rendered section — MANDATORY when `mustInject` is true

When the status JSON has `"mustInject": true` (it is, for `"ran": true` and for
`"reason": "fresh"`), the Figma design section is **non-negotiable** in the
document being generated — **never omit it, whatever your model**. The script has
already rendered a ready-to-paste section to the path reported in the field that
matches the current phase:

| Current command | Field to use | Insert into |
|---|---|---|
| `/speckit.specify` | `specSection` | `spec.md` |
| `/speckit.plan` | `planSection` | `plan.md` |
| `/speckit.tasks` | `tasksSection` | `tasks.md` |

Do this, in order:

1. **Paste the rendered block VERBATIM** from that file into the generated
   document. Its "Snapshot facts (auto-filled)" appendix lists the real file,
   pages, frames and input links — keep it.
2. **Complete the judgement placeholders** left in the block (component placement
   reuse/create, justification, token mapping) by loading
   `.figma/context-snapshot.json` and applying the rules of
   `/speckit.figma.introspect` sections 3-7 (frame confirmation, 3-level
   placement, token gaps, tests + Storybook sub-tasks).
3. Treat any `links` in the status JSON as authoritative design targets for the
   affected components.

If a `*Section` field is `null` (rendering failed, e.g. a missing template), the
section is STILL mandatory: build it from
`./.specify/templates/{spec,plan,tasks}-figma-section.template.md` plus the
snapshot. Do not skip it.

## 3. Broad / ambiguous Figma links → confirm a frame, never skip silently

When `"linkScope": "broad"`, the input pointed at a whole file or page (multiple
frames, no specific frame selected). Do **NOT** write "the creative was not
explicitly indicated" and move on. Instead:

1. Present the `candidateFrames` from the status JSON as a **numbered list**
   (frame name + node id, grouped by page). **If `candidateFrames` is empty**
   (the snapshot has no frame index yet — e.g. a project/team-only run), first
   run `/speckit.figma.introspect --file <id>` to enumerate the file's frames,
   then present them. Do not skip the checkpoint just because the list arrived
   empty.
2. Ask the developer **which frame(s)** the feature targets — this is the
   creative-confirmation checkpoint.
3. Once they answer, re-run with the chosen frame (the precise deep link, or
   `/speckit.figma.introspect --file <id> --node <nodeId>`), then proceed.

Only if the developer does not answer do you continue without a pinned creative —
and then you record a visible warning in the document, not a silent omission.
When `"linkScope": "frame"`, the creative is already pinned: proceed directly.

## 4. Other skip reasons

For any other `reason` (`no-config`, `unresolved-placeholders`, `target-excluded`,
`target-not-mapped`, `target-disabled`, `ambiguous-target`, `invalid-config`,
`dry-run`) — proceed without Figma context and add a short note mentioning the
reason. Never block generation.

### `introspect-failed` — report the true cause, never guess

When `"reason": "introspect-failed"`, the JSON also carries a `code` field with
the machine-classified failure cause. Read it and report **that** cause — do not
assume the token is at fault:

| `code` | Cause | What to tell the user |
| --- | --- | --- |
| `NETWORK` | proxy/connectivity failure; the PAT was never rejected | the corporate proxy or network cannot reach `api.figma.com` (the auto-retry already stripped the proxy and still failed). The token is **not** the problem. See docs/CREDENTIALS.md → "Troubleshooting — proxy vs auth". |
| `AUTH` | `401/403` — token missing/invalid or lacking a scope | the PAT is missing, expired, or lacks `projects:read` / `file_content:read`. See docs/CREDENTIALS.md. Never suggest exporting the token by hand or creating a `.env`. |
| `NOT_FOUND` | `404` — wrong key or non-member | the file/project/team key is wrong, or the PAT owner is not a member of that team. |

For any other or absent `code`, fall back to the generic note above. Then
proceed without Figma context — never block generation.

## 5. Credentials hygiene

Never read, print or echo the Figma token (`FIGMA_PAT`, keychain).
The scripts load it internally; you only ever need their JSON output.
