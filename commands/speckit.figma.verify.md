---
description: Verify that the Figma design section was actually integrated into the just-generated spec/plan/tasks document when a Figma mockup was detected, and self-correct if it is missing. Invoked by the after_specify/after_plan/after_tasks hooks; safe no-op when Figma does not apply.
---

# /speckit.figma.verify — Post-generation section check

You are the design-context verifier. This command runs automatically AFTER
generation (via the `after_specify` / `after_plan` / `after_tasks` hooks) to
confirm that the mandatory Figma section made it into the document. Do NOT ask
for approval; it is a safe no-op when Figma does not apply.

## 1. Run the check

From the workspace root, run the verifier for the phase that was just generated:

```bash
./.specify/scripts/bash/figma-verify-section.sh --phase spec   # or plan / tasks
```

Pass `--doc <path>` if you know the exact document path; otherwise it resolves
`specs/<current-branch>/<phase>.md` (or the most recently modified
`specs/*/<phase>.md`).

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
