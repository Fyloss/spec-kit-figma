---
description: Export Figma nodes to image files — either confirmation previews written beside the spec so the developer validates the creative visually, or production assets (logo as .svg, mock as .png) written where the project keeps them and recorded in a manifest. Run on demand; never automatic.
---

# /speckit.figma.export — Figma nodes to image files

You are the design-asset exporter. Unlike the other Figma commands this one is
**not hooked**: it writes files into the repository, so it runs only when the
developer asks for it.

Two modes. They share one Figma endpoint and nothing else — their lifecycles are
opposite, so never use one where the other belongs.

## Mode `preview` — confirm the creative by looking at it

Design rule 5 asks the developer to confirm which frame a feature targets. A list
of node ids is a poor way to ask; a picture is not.

```bash
./.specify/extensions/figma/scripts/bash/figma-export-images.sh \
  --file <fileKey> --node <id> [--node <id> ...]
```

On Windows use `scripts/powershell/figma-export-images.ps1` — same flags, same
JSON report.

- Defaults to PNG at scale 2, written to **`specs/<feature>/assets/`**.
- **Commit them.** `.figma/cache/` is git-ignored, so a preview written there is
  invisible to a reviewer on GitHub and `spec.md` renders a broken image. A few
  tens of KB in the repository costs less than a broken image in a reviewed spec.
- Reference each one from the spec next to the candidate-frames table:
  `![Hero frame](assets/12_345.png)`.

**Use it when** the ensure status reports `linkScope: "broad"` or `"oversized"`
and you are about to ask which frame the feature targets. Export the candidates,
show them, then ask.

## Mode `asset` — pull a real asset the implementation ships

```bash
./.specify/extensions/figma/scripts/bash/figma-export-images.sh \
  --mode asset --file <fileKey> --node <id> --format svg --out <dir>
```

- Defaults to SVG. Use `--format png --scale 2` (or 3) for raster.
- **`--out` is mandatory.** Where a shipped asset belongs — the Design System, or
  one app — is a placement decision, exactly like component placement (design
  rule 2). Resolve it the same way, and **ask the developer when it is
  ambiguous**. The script refuses to pick a default on purpose.
- A `.figma-assets.json` manifest is written next to the assets. It records what
  the export produced, so a re-run reports `unchanged` instead of re-downloading,
  and refuses (`skipped-modified`) to overwrite a file a human has edited since.
  **Never pass `--force` on your own initiative** — it exists so a developer can
  deliberately discard a manual edit.

## Rules

- **Never export a whole page's worth of nodes speculatively.** Export the
  candidates you are about to show, or the assets a task actually needs.
- **Report the result, do not narrate it.** The JSON report carries `exported`
  (with per-node `status`) and `failed`; surface failures with their reason and
  move on. A node Figma could not render is reported as `no-image-returned`, not
  silently missing.
- **Committed files are the developer's call.** Say which files you wrote and
  where; do not stage or commit them yourself unless asked.
- The rendered image URL is a signed CDN link, never a Figma API endpoint: the
  script downloads it without the token, and so must anything you write.
