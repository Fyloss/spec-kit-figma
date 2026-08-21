---
description: Report whether the Figma file changed after the feature's spec was generated, by comparing the lastModified recorded in the section marker with the current snapshot. Invoked by the after_analyze hook; safe no-op when the feature carries no design section.
---

# /speckit.figma.drift — Post-analysis design-drift check

You are the design-drift reporter. This command runs automatically AFTER
`/speckit.analyze` (via the `after_analyze` hook). Do NOT ask for approval; it is
a safe no-op when the feature has no design section.

`/speckit.analyze` cross-checks `spec.md`, `plan.md` and `tasks.md` against each
other. It cannot see the one Figma fact that matters here: the three documents can
agree perfectly and all be faithful to a creative the designer has since changed.
On a PR that has been open for two weeks, that is the drift that produces an
implementation faithful to an obsolete design.

## 1. Run the check

From the workspace root:

```bash
./.specify/extensions/figma/scripts/bash/figma-check-drift.sh
```

On Windows, run the PowerShell 7+ port instead (same flags, same JSON output):

```powershell
./.specify/extensions/figma/scripts/powershell/figma-check-drift.ps1
```

It defaults to `--phase spec` — the document that records the creative. Pass
`--doc <path>` when you know the exact path; otherwise it resolves
`specs/<current-branch>/spec.md` using the same rules as the other helpers.

The comparison is between two RECORDED facts, never a re-render: the Figma
`lastModified` captured in the section marker when the document was generated,
and the `lastModified` of the snapshot the `before_analyze` hook just refreshed.

## 2. Act on the reported reason

| `reason` | Meaning | What you do |
|---|---|---|
| `ok` | The design has not moved since the spec was generated | Say nothing. Do not add a note to any document. |
| `drifted` | **The Figma file changed after the spec was generated** | Report it in your chat reply, quoting both timestamps and the `remedy`. Name the risk explicitly: tasks derived from the old creative may now be wrong. |
| `not-applicable` | The snapshot targets a different file than the document | Say nothing — the creative legitimately moved files. |
| `no-marker` | The feature carries no Figma section | Say nothing. This is a design-less feature. |
| `doc-not-found` / `no-snapshot` | Nothing to compare | Say nothing. Being unable to check is not a finding. |
| `unknown-timestamp` | The document predates drift tracking | Mention once that drift tracking starts at the next regeneration. |

## 3. Rules

- **Never edit a document.** This command reports; it does not correct. Refreshing
  the design section is `/speckit.specify` or `/speckit.figma.ensure`, and that is
  the developer's call — a creative that moved may or may not invalidate the work
  already done.
- **Never invent drift.** Only `reason: "drifted"` is drift. An absent snapshot, a
  missing marker or a document from before the marker carried timestamps are all
  *unable to check*, which is not a finding and must not be reported as one.
- **State it once, plainly.** A drift report is one or two sentences in the chat
  reply, with both timestamps. Do not open a task, do not block, do not ask.
- `--strict` (or `figma.verifyStrict: true` in `figma.projects.config.json`) makes
  a real drift exit non-zero so CI can gate on it. Being unable to check still
  exits 0 under `--strict`: the gate fires on evidence, never on its absence.
