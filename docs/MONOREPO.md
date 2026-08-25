# Repository topologies (single-repo, mono-repo, multi-repo)

The extension defaults to a **single-repo** layout (one repository holding a
single front-end app). It also supports a **mono-repo**, where apps and libraries
live as packages inside a single repository (Nx, Turborepo, pnpm/yarn workspaces,
Lerna), and a **multi-repo parent** (a host repo with front-end repositories
wired as git submodules).

## What changes between the modes

| Concern | Single-repo (default) | Mono-repo | Multi-repo |
|---|---|---|---|
| Config key | `repo` (single object) | `repo` (single object) | `submodules` (map keyed by repo name) |
| Target identity | the repo / app itself | package name (app/lib) inside the repo | git submodule / repo name |
| `submodulePath` | `"."` (repo root) | `"."` (repo root); packages located via `monorepo.apps`/`libs` | path of each submodule |
| Design System | a folder/lib inside the repo (e.g. `src/design-system`) | a lib inside the repo (e.g. `libs/design-system`) referenced via `designSystem.ref` + `submodulePath` | a separate submodule (e.g. `design-system`) referenced via `designSystem.ref` |
| Target detection | always resolves to the single `repo` | match the package against `repo.monorepo.apps`/`libs`, or the repo itself | match against `submodules[<name>]` |
| Everything else | identical | identical | identical |

The page-to-package mapping, routing rules, 3-level component resolution, shared
mockups, token mapping, responsive rules and credential handling are **the same**
in every mode. Only the topology wrapper differs.

> **Windows note:** every command below has a PowerShell 7+ twin — replace
> `./.specify/extensions/figma/install.sh` with `pwsh -File ./.specify/extensions/figma/install.ps1` and
> `./.specify/extensions/figma/scripts/bash/<name>.sh` with
> `./.specify/extensions/figma/scripts/powershell/<name>.ps1` (same flags, same JSON output).

## Single-repo setup

1. Install in single-repo mode (the default):
   ```bash
   ./.specify/extensions/figma/install.sh
   ```
2. Edit `figma.projects.config.json` (see
   `config/figma.projects.config.singlerepo.example.json`):
   - set `"mode": "single-repo"` and fill the single `repo` object;
   - point `designSystem` at the internal DS folder/lib (`submodulePath` +
     `tokenSource`);
   - optionally map Figma pages with `pageToPackageMapping` and tune
     `routingRules`.
3. Validate and detect:
   ```bash
   ./.specify/extensions/figma/scripts/bash/figma-validate-config.sh
   ./.specify/extensions/figma/scripts/bash/figma-detect-target.sh repo
   ```

## Mono-repo setup

1. Install in mono-repo mode:
   ```bash
   ./.specify/extensions/figma/install.sh --mode mono-repo
   ```
2. Edit `figma.projects.config.json` (see
   `config/figma.projects.config.monorepo.example.json`):
   - set `"mode": "mono-repo"` and fill the single `repo` object;
   - declare apps/libs under `repo.monorepo.apps` / `repo.monorepo.libs`;
   - point `designSystem` at the internal DS lib (`ref` + `submodulePath` +
     `tokenSource`);
   - map Figma pages to internal packages in `pageToPackageMapping`;
   - list non-front packages (BFF, tools) under `excluded`.
3. Validate and detect:
   ```bash
   ./.specify/extensions/figma/scripts/bash/figma-validate-config.sh
   ./.specify/extensions/figma/scripts/bash/figma-detect-target.sh app-storefront
   ./.specify/extensions/figma/scripts/bash/figma-detect-target.sh app-bff   # → excluded
   ```

## Component placement in a mono-repo
The 3 levels map naturally to internal packages:
1. **Reuse** → existing component in the `design-system` lib.
2. **Create in Design System** → new component in the `design-system` lib, but
   only if purely presentational (no business logic) and shared across apps.
3. **Create in app / shared lib** → app package for app-specific components, or a
   domain/shared lib (e.g. `lib-ui-shared`, `lib-cart-domain`) for shared ones.

Shared mockups (header + user account, product detail page add-to-cart shared by several apps) resolve
to the shared lib or the Design System lib and are consumed by each app — never
duplicated.

## Recommendation
Prefer driving placement by **package name** (stable) rather than filesystem path,
so refactors that move folders do not break the mapping. Keep `figmaFileId` per
logical area if your mono-repo uses multiple Figma files; otherwise a single
`figmaFileId` with a rich `pageToPackageMapping` is sufficient.

## Autonomous introspection is per target, not per workspace

`autoIntrospect` decides what happens when a feature carries **no Figma link**,
and it is declared on the target — which is the whole point in a mono- or
multi-repo. The two halves of the same workspace rarely deserve the same policy:

```jsonc
"design-system": { "autoIntrospect": { "mode": "always", "maxFrames": 40 } },
"storefront":    { "autoIntrospect": { "mode": "off" } }
```

A small, self-contained design-system file can be read whole; a large product
file cannot, and should keep requiring a pinned node id. `off` is the default, so
a target that says nothing keeps the link-only contract.

In **mono-repo** mode the setting sits on `repo` and therefore applies to every
app and lib it contains — `figma-detect-target` resolves any package of the
mono-repo to that same `repo` node. One Figma file, one policy. Only
**multi-repo** gives a policy per submodule.

`autoIntrospect` requires `figmaFileId` on the target: a project or team id would
have the hook crawl an entire organisation, which is `/speckit.figma.introspect`'s
job, run by hand. See the table below for those levels, and the README for the
three modes and the `maxFrames` budget.

## Figma design source levels (file / project / team)
Independently of the repo topology, each target points at its Figma design via one
of three levels — pick the one that matches how the design org is structured:

| Field | Scope | Autonomous discovery |
|---|---|---|
| `figmaFileId` | A single Figma file | Pages and frames of that file. |
| `figmaProjectId` | A whole project | Every file of the project, then their pages. |
| `figmaTeamId` / `figmaTeamIds` | A whole team (or several teams) | Every project of each team, then every file, then their pages. |

Use `figmaTeamId` (or `figmaTeamIds` when a target spans several teams) for a
**Figma organization with multiple teams, each holding multiple projects**: the
agent walks the full **organization > team > projects > files** tree and writes a
nested index into `.figma/cache/context-snapshot.json`. See
`config/figma.projects.config.organization.example.json`. At least one of the
three fields MUST be set per enabled target; the token must have access to any
team it enumerates.

