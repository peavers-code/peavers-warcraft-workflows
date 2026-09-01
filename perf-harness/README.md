# Ultra Performance harness

Measures a Peavers addon against a budget it declares itself, and fails the
build when it regresses.

The point is that **"Ultra Performance" has to be falsifiable**. A README that
claims an addon is light is worth nothing; a README whose numbers are
regenerated from the real source on every push, by a job that goes red when they
get worse, is worth something. Everything in this directory exists to keep that
property.

## What an addon supplies

```
perf/
  budget.json        the limits it holds itself to
  cases/*.lua        optional behavioural scenarios
README.md            containing <!-- perf:begin --> and <!-- perf:end -->
.github/workflows/perf.yml   a caller for the reusable workflow
```

### `perf/budget.json`

```json
{
  "maxWidgetCallsPerFrame": 1,
  "maxCallsPerSecond": 40,
  "maxIdleCallsPerSecond": 0,
  "maxPackagedKB": 100,
  "allowBundledLibs": false
}
```

Every key is optional; omitting one drops that check. Set numbers you actually
meet today, not aspirations — a budget that already fails teaches the team to
ignore a red build, which costs more than it buys.

`maxCallsPerSecond` is for timer-driven addons. Per-frame is the wrong unit for
something that runs on a `C_Timer` ticker: it does no per-frame work at all, and
the honest question is what a tick costs and how often one happens. A scenario
opts in by reporting `callsPerSecond` alongside (or instead of) `callsPerFrame`,
and the badge falls back to a per-second headline when nothing runs per frame.

### `perf/cases/*.lua`

A case loads real addon files into a Lua VM against instrumented widget stubs,
drives them, and returns what it measured:

```lua
local Stubs = dofile(HARNESS_LIB .. "/wow-stubs.lua").Install()

-- Load the real file under test. ADDON_DIR and HARNESS_LIB are set by the runner.
local CastBar = assert(loadfile(ADDON_DIR .. "/src/UI/CastBar.lua"))("MyAddon", MyAddonNamespace)

-- ... set the addon up, then drive its OnUpdate ...

return {
  {
    name = "player cast, 2.5s at 144fps",
    callsPerFrame = Stubs.Drive(function(dt) bar:OnUpdate(dt) end, 360, 1 / 144),
    idleCallsPerSecond = 0,
    notes = "one SetValue; spark rides the fill texture",
  },
}
```

The case owns its own setup. `wow-stubs.lua` deliberately models only what a
measurement depends on — call counting, frame visibility, status bar values —
and makes everything else an inert no-op. If a case needs more, it stubs it.

**Watch the `_`-prefixed field rule in the stubs.** The catch-all `__index`
returns a callable for any unknown key, so without the guard an unset `_text`
reads back as a function rather than `nil`, and assertions about it pass
silently. That has already caused one false green.

## What the harness measures

| Check | How |
|---|---|
| Packaged size | Walks the repo, skipping what `.pkgmeta` ignores |
| Bundled libraries | A top-level `Libs`/`libs` directory |
| Widget calls per frame | Counted for real while a case drives the addon's own handler |
| Widget calls per second | For timer-driven addons: what a tick costs, times how often it fires |
| Idle calls per second | Same, with nothing happening — should be zero, since WoW does not tick hidden frames |

`callsPerFrame` is the honest total of everything the addon asked the client to
do, averaged over the run. It is not a proxy or a score.

## Running it locally

```bash
cd perf-harness && npm install
node runner.mjs --addon /path/to/PeaversCastBar
```

Add `--readme /path/to/README.md` to rewrite the table in place, `--json` for the
full report, and `--badge` to emit the shields.io endpoint document.

Exit code is 1 when the budget is exceeded, 2 when the addon declares no budget.

## Wiring an addon up

`.github/workflows/perf.yml` in the addon repo:

```yaml
name: Ultra Performance
on:
  push:
    branches: [master]
  pull_request:
    branches: [master]
  workflow_dispatch:

# Required. See the note below.
permissions:
  contents: write
  id-token: write

jobs:
  perf:
    uses: peavers-code/peavers-warcraft-workflows/.github/workflows/perf.yml@master
    with:
      addon_name: PeaversCastBar
      use_self_hosted: true
    secrets: inherit
```

**Do not omit the `permissions:` block.** A reusable workflow cannot be granted
more than its caller has, and this one needs `contents: write` to publish the
measured table back into the README and `id-token: write` to mint the App token
via Vault OIDC. Leave it out and the run fails at *startup*: no job is created,
there is no log to open and no annotation on the pull request — just a bare
`startup_failure`, which looks identical to the reusable workflow not existing.
All three addons hit this on their first run.

Then add the badge and the markers to the README:

```markdown
[![Ultra Performance](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/peavers-warcraft/PeaversCastBar/master/.github/badges/perf.json)](https://github.com/peavers-warcraft/PeaversCastBar/actions/workflows/perf.yml)

<!-- perf:begin -->
<!-- perf:end -->
```

The badge reads a JSON document the job commits into the repo, so there is no
external service to keep alive and no account to lose.

Finally set `ultraPerformance: true` in the addon's `.peavers.yml` so
addons.peavers.io shows the programme badge on its card and detail page.
