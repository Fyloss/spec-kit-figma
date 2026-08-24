# Figma Extension — Design Rules (project overlay)

This file is YOURS. The spec-kit-figma extension creates it once and **never**
overwrites it, so everything you put here survives `/speckit.figma.update`.

It is loaded by the agent **immediately after** the extension-owned base
(`.figma/figma-design-rules.md`). On conflict, **the overlay wins**: a rule here
adds to, refines, or overrides the matching base rule. When this file is empty,
only the base rules apply.

**Commit this file** — it is part of your project's design contract, and CI /
GitHub Cloud Agents only see committed files. Do NOT git-ignore it.

Add your own rules below. A few common overrides are shown, commented out; delete
the comment markers on the ones you want, and add sections of your own.

<!--
## Declare rule 4 — Responsive policy (mobile-first, tablet interpolated)
- This project is **mobile-first**. Every app MUST also be responsive on **tablet**
  breakpoints, **even when no tablet mockup exists**: interpolate the tablet layout
  from the mobile and desktop frames and state the interpolation explicitly.
  (For a desktop-only product write instead: "Desktop-only — implement the desktop
  frame as designed; do NOT infer tablet/mobile breakpoints.")
-->

<!--
## Tighten rule 7 — Storybook is mandatory
- This project uses **Storybook**. A UI change is incomplete unless it also
  creates/updates the matching `*.stories.*` entry, on top of the automated tests
  base rule 7 already requires.
-->

<!--
## Declare rule 6 — Design-token gap process
- When a token gap is detected (base rule 6), open a task and notify the design
  system owner via <your process: Slack channel, GitHub label, CI trigger, …>.
  The agent still never edits the Design System directly.
-->

<!--
## Declare rule 6b — Unit & scale contract  ← the one most projects need
- Figma values arrive as **absolute CSS px at 1x** (`70px`, never a bare `70`).
  Convert them with `pxToRem()` from `src/theme/units.ts` — a 70px margin becomes
  `pxToRem(70)`.
- **NEVER pass a raw Figma px value to a scale-indexed helper.** This theme is
  built with `createTheme({ spacing: 4 })`, so `theme.spacing(70)` is **280px**,
  not 70px: `theme.spacing(n)` takes a scale INDEX, never a px value. The same
  trap exists in Tailwind (`mt-70` is 17.5rem = 280px) and in any spacing scale.
- A value with no exact step on the scale keeps the explicit conversion
  (`pxToRem(70)`) and is recorded as a token gap (rule 6). Never round it to the
  nearest step in silence — the designer chose 70.
-->

<!--
## Add a project-specific rule — Component naming
- Design System components MUST be named in PascalCase and prefixed with `Ds`
  (e.g. `DsButton`, `DsCard`). Reject any generated component that does not.
-->
