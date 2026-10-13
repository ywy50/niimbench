---
name: cordis-review
description: >
  Review the current codebase against the CORDIS context paradigm
  (arXiv:2608.25512) and implement every applicable fix. Use when the
  user says "cordis review", "review against CORDIS", "spatiotemporal
  composability", or invokes /cordis-review. Targets plugin systems,
  harnesses, and any code that loads, unloads, or depends on components
  at runtime.
---

# CORDIS review

**Kind:** `cookbook`

Your goal is to review component effects, reactive dependencies and unload behavior against the CORDIS context paradigm.

This review applies to a workspace whose runtime loads, unloads or depends on
components at runtime through a context. With no such runtime, report the skip
and stop without edits.

Review this workspace against **A Programming Paradigm for Spatiotemporal
Composability** (Shi, Zhang, Cui; [arXiv:2608.25512](https://arxiv.org/abs/2608.25512))
and **implement every applicable fix**. Report-only is failure. Skip a finding
only when the paper's own system-boundary argument says the effect cannot be
tracked.

**This file is the checklist — start here.** It is the operational form of
the paper and is sufficient to review and patch; the agent is not required to
fetch anything before auditing.

The following fetch notes describe the original source environment; current
tool availability and URL responses must be checked when a fetch is needed.

Paper fetch, if you want the abstract and exact metadata: the **abs page only**
— <https://arxiv.org/abs/2608.25512> (HTTP 200). Do **not** try the PDF
(`/pdf/2608.25512`: this harness rejects `application/pdf`) or an HTML
rendering (`/html/2608.25512v1` is 404 — no HTML is published for this
submission). The abstract is not the checklist: rules come from this file, not
from a fetched page, and never from memory. The `§` numbers below are cited
from the paper's section structure and were verified against it; do not
re-derive or second-guess them mid-review.

If the workspace is DeepSeek Harness or a `dsh-*` plugin, also obey that
repo's Cordis conventions (`AGENTS.md`, `docs/cordis-primer.md`,
`docs/cordis-tutorial/`). The paper wins on the model; the repo wins on
names (`ctx.effect`, `inject`, `ctx.get`, `apply`).

## Protocol

1. **Scope.** Default: the current workspace. A `/cordis-review <path>`
   argument, if present, is the root. Do not wander into unrelated checkouts.
2. **Get the rules.** Read this file's **Checklist** and **What the paper
   requires** sections — that is the complete rubric, already loaded. If you
   need the paper's abstract or exact metadata, `web_fetch` the abs page
   `https://arxiv.org/abs/2608.25512` (the only URL that works; the PDF is
   rejected and there is no HTML rendering). In DSH / `dsh-*` plugin
   workspaces, also read that repo's `AGENTS.md` and `docs/cordis-primer.md`;
   those are the local naming and convention source of truth.
3. **Map the runtime.** Find the context object, effect/coeffect primitives,
   component/plugin entrypoints (`apply` / `inject` / `Service`), and the
   loader. In DSH/Cordis that is `ctx`, `ctx.effect` / `ctx.on` / `ctx.set`,
   `inject`, fibers, and the Loader.
4. **Closed-form pass.** The checker below is external and optional. It
   applies only when the package that ships `src/cli.ts` is actually present;
   this prompt does not ship it, so by default audit the full checklist
   directly and record the checker as unavailable. Never install it.

   When that package is present, run its checker before walking the rest of
   the checklist, from its root: two levels above this prompt's directory
   (`<package>` when the prompt ships at `<package>/skills/cordis-review/`). Inspect
   its help and substitute the real scope before executing.

   `node --experimental-strip-types --disable-warning=ExperimentalWarning src/cli.ts [scope]`

   It prints `file:line: tag: message` for `mix-export`, `inject`,
   `toplevel`, and `id` — every tag is one ast-grep query. Without `ast-grep`
   on PATH each covered file warns on stderr and yields an LLM-fallback hit:
   judge that file against the checklist yourself (that is the fallback, not a
   second scanner). The binary ships no Zig grammar, so `.zig` takes that
   path unless the CLI is given a grammar registry
   (`--grammar-config <sgconfig.yml>` — an `sgconfig.yml` with a `zig`
   language). `--ast-grep` forces the engine on, `--no-ast-grep` forces the
   fallback path, and `--help` lists both. `leak` / `inverse` / `hmr` /
   `boundary` stay judgment, and a clean run still means walk the checklist.
5. **Audit, then fix.** Walk the checklist below. Each hit is a code change
   unless it is a documented outside-boundary emission. Grep callers of every
   function you touch; fix the shared primitive, not one call site.
6. **Verify.** One HMR/dispose test per registration you add or repair: dispose
   the contributing fiber, assert the contribution is gone. Run the smallest
   existing test command that covers the files you changed. Re-run the checker
   when step 4 found one.

## What the paper requires

Two orthogonal properties, local to one component, then lifted to a system of
interleaved components:

- **Temporal composability.** Every context mutation carries an inverse the
  runtime holds. Unload runs those inverses LIFO. A leftover timer, listener,
  registry row, or published service after dispose is a bug.
- **Spatial composability.** A component declares what it requires
  (coeffects). The runtime classifies every context change against that
  declaration and activates or deactivates the component. A missing provider
  leaves it inactive; it does not crash, and it does not reach around the
  declaration.

The **context paradigm** mediates every effect and coeffect through one
context. Reaching another component's context through a closure, import, or
global leaks effects out of the owner's lifecycle and coeffects out of its
`inject` list.

The runtime does **not** prove that an inverse actually reverts, or that
operations published at one key commute. Those are author obligations
(§5.1.1 effect tracking — "Effect tracking" is the only context-transformation
primitive, and the runtime does not check the inverse witness; §6.1 "System
Boundary"). This review discharges them in code.

## Checklist

One line per finding in the report, then the patch.

### Temporal — revertible effects

- `leak:` side effect not installed through the context (`setInterval`,
  `addEventListener`, `on()`, `fetch` abort, file watch, process, mutex,
  module-level singleton mutation). Wrap in `ctx.effect(() => { …; return dispose })`
  or the helper that already does (`ctx.on`, `register()` that returns a
  disposer).
- `inverse:` dispose does not restore the pre-effect state, is not idempotent,
  or is not LIFO with sibling effects. Inverse fires at most once.
- `toplevel:` work at module load (register, listen, I/O, `new Service`)
  instead of inside `apply(ctx)` / the Service constructor. Move it.
- `double:` dispose path can run the inverse twice, or never. Guard like
  Cordis `armed`.
- `foreign-ctx:` effect installed on a context that is not `fiber.ctx`
  (captured parent, global, another plugin's `ctx`). Install on the owner.

### Spatial — reactive coeffects

- `inject:` required service used as `ctx.foo` without `inject: ['foo']`.
  Declare it. Optional services use `ctx.get('foo')`, never the proxy.
- `bypass:` dependency reached by import, global, or hard-coded singleton
  instead of the context key. Route through `ctx`.
- `provide:` published service / registry row not a tracked effect
  (`ctx.set`, `ctx.plugin`, `register` returning a disposer). Make it one.
- `mix-export:` default-export Service **and** named `apply`/`inject` on the
  same module. Loader keeps one form; mixing drops `inject`. Pick one.
- `react:` component assumes a coeffect is eternal. It must survive provider
  swap / withdraw (stay inactive until the key returns; do not throw in
  `apply` for a missing optional).

### Context paradigm

- `mediate:` shared mutable environment written outside `ctx` (process global,
  imported registry, `window.*`, file side-channel used as a bus). Put it on
  a service key.
- `config:` runtime behavior that belongs in the component's `config` /
  Loader entry is a magic constant or env read inside `apply`. Bind config;
  invalid values fail at load, not later.
- `isolate:` cross-plugin state sharing that should be a realm (`isolate`)
  or a declared service, implemented as a module singleton.

### System boundary (§6.1)

- **Inside:** exclusive and restorable → must be a tracked effect.
- **Outside:** cannot restore (bytes already on the wire, other processes
  writing the file) → do not fake an inverse. Either **withhold** until
  commit or **compensate** with an application-level undo, and say so in a
  one-line comment (`cordis-boundary: emission, compensate by X`).
- `boundary:` treats an inside location as outside (leaks) **or** invents a
  "cleanup" for an emission it cannot revert (lies). Fix the classification.

### Lifecycle / loader

- `fiber:` retains a child plugin / subscription past owner dispose.
  Keep the fiber and dispose it in the owner's effect.
- `hmr:` registration has no dispose-the-fiber test. Add one.
- `id:` duplicate Loader `id` / plugin name, or a bundle patch that `insert`s
  the same row the profile already has.

## DSH / Cordis names

Map paper → this stack without renaming the stack:

| Paper | Code |
|---|---|
| context Γ | `ctx` |
| revertible effect | `ctx.effect`, `ctx.on`, `register()` → disposer |
| coeffect declaration | `export const inject = ['…']` |
| coeffect read | `ctx.foo` (required) / `ctx.get('foo')` (optional) |
| coeffect provide | `ctx.set` / Service constructor key |
| component | `export function apply(ctx)` or `class extends Service` |
| fiber | return value of `ctx.plugin(…)` |
| inverse accumulator | `fiber.dispose` |
| loader entry | `cordis.yml` / `cordis.patch.yml` row |

Harness conventions that already encode the paper: registrations are
effects; `ctx.get` for optional services; function plugins named-export
`name` / `inject` / `Config` / `apply` with **no** default export; every
registry has an HMR-safety test.

## Fixes

- Order the pass: leaks and cross-context bypasses first, then inverses and
  lifecycle, then loader identity. Fix what you can prove and test this pass;
  record every remaining hit with its file, line and tag so the next pass
  resumes where this one stopped.
- Smallest change that restores the invariant. Deletion over a new
  abstraction. No "lifecycle manager" class for one timer.
- Do not add a framework, a second context type, or a compatibility shim.
- Do not rewrite working Cordis usage into a parallel effect system.
- Leave theory, proofs, and comments that are not lying. Code only.
  Apply the target project's docs-with-code requirements when a fix changes
  a documented contract or procedure.
- If a hit is outside this workspace (vendored Cordis, another repo), record
  it as `out-of-scope:` and do not patch it.

## Report (after the patches)

Under Gauntlet, its supplied output and Git-ownership protocol governs the
run; do not invoke another review runner. The original format below is for
direct sessions. Keep unverified scope explicit rather than implying a pass.

> CORDIS review — arXiv:2608.25512
>
> scope: `<root>`
>
> fixed:
>
> - `<file>:<line>: <tag> <what>. <what you did>.`
>
> skipped:
>
> - `<file>:<line>: <tag> <what>. <why: boundary | out-of-scope | already-correct>`

No essay. Empty `fixed` with empty `skipped` means you looked and the
workspace already holds the invariants — say that in one line.
