---
description: Verify that the Figma design section was actually integrated into the just-generated spec/plan/tasks document when a Figma mockup was detected, and self-correct if it is missing. Invoked by the after_specify/after_plan/after_tasks hooks; safe no-op when Figma does not apply.
---

# /speckit.figma.verify — Post-generation section check

You are the design-context verifier. This command runs automatically AFTER
generation (via the `after_specify` / `after_plan` / `after_tasks` hooks) to
confirm that the mandatory Figma section made it into the document. Do NOT ask
for approval; it is a safe no-op when Figma does not apply.

## 1. Run the check

Pick `--phase` from the hook that invoked you — it MUST match the document that
was just generated. NEVER default to `spec`: this one command file is shared by
all three after-hooks, so verifying the wrong phase would let a missing
plan/tasks section pass silently (and pass a `--strict` CI gate).

| Invoking hook | Generated document | Use |
|---|---|---|
| `after_specify` | `spec.md` | `--phase spec` |
| `after_plan` | `plan.md` | `--phase plan` |
| `after_tasks` | `tasks.md` | `--phase tasks` |

From the workspace root, run the verifier with the matching phase (substitute
`<phase>` using the table above):

```bash
./.specify/scripts/bash/figma-verify-section.sh --phase <phase>
```

Pass `--doc <path>` if you know the exact document path; otherwise it resolves
`specs/<current-branch>/<phase>.md`, or the single `specs/*/<phase>.md` when
exactly one exists. With several candidates it refuses (reason `doc-not-found`)
and asks for `--doc` instead of guessing the wrong feature's document.

## 2. Interpret the status JSON

- `"reason": "not-applicable"` — no Figma section was rendered for this run
  (Figma did not apply). Nothing to do.
- `"reason": "ok"` — the section is present. Done.
- `"reason": "doc-not-found"` — the document could not be located. Re-run with
  `--doc <path>`; do not block.
- `"reason": "section-missing"` — **a Figma mockup was detected but the section
  is absent from the document.** This is a defect: **insert the rendered block
  from `renderedSection` verbatim** into the document at `doc` now, complete the
  judgement placeholders (placement, justification, token mapping) per the rules
  of `/speckit.figma.introspect` sections 3-7, then re-run this check to confirm
  it reports `"ok"`.

## 3. CI / strict mode

In a pipeline, run with `--strict` (or set `figma.verifyStrict: true` in
`figma.projects.config.json`): a `section-missing` result then exits non-zero so
the build fails when a detected Figma mockup was not integrated.

## 4. Credentials hygiene

This command reads only local files; it never needs the Figma token.
