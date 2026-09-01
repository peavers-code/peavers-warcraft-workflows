#!/usr/bin/env node
/**
 * Ultra Performance harness runner.
 *
 * Measures an addon against its declared budget and fails when it regresses.
 * The point of the exercise is that the "Ultra Performance" claim is
 * falsifiable: every number in the README is produced here, on every push, from
 * the addon's real source rather than from a comment someone wrote once.
 *
 * Two kinds of check:
 *
 *   static       - always run. Packaged size and bundled libraries, derived
 *                  from the repo the same way .pkgmeta packages it.
 *   behavioural  - run when perf/cases/*.lua exist. Each case loads real addon
 *                  files into a Lua VM against instrumented widget stubs and
 *                  reports what the addon actually asked the client to do.
 *
 * Usage: node runner.mjs --addon <dir> [--json out.json] [--markdown out.md]
 *                        [--badge out.json] [--readme README.md]
 */

import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i].startsWith('--')) {
      const key = argv[i].slice(2);
      const next = argv[i + 1];
      if (next && !next.startsWith('--')) { out[key] = next; i += 1; }
      else out[key] = true;
    }
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
const addonDir = args.addon || process.cwd();

// ---------------------------------------------------------------------------
// Budget
// ---------------------------------------------------------------------------

const budgetPath = join(addonDir, 'perf', 'budget.json');
if (!existsSync(budgetPath)) {
  console.error(`No perf budget at ${budgetPath}.`);
  console.error('An addon in the Ultra Performance programme must declare one.');
  process.exit(2);
}
const budget = JSON.parse(readFileSync(budgetPath, 'utf8'));

// ---------------------------------------------------------------------------
// Static checks
// ---------------------------------------------------------------------------

// Mirrors the .pkgmeta ignore list. Kept in step with it by hand deliberately:
// parsing .pkgmeta would couple the budget to a packaging format that changes
// for reasons that have nothing to do with performance.
const IGNORE_DIRS = new Set(['.git', '.github', '.claude', 'node_modules', 'perf', '.release']);
const IGNORE_FILES = new Set([
  '.gitignore', '.editorconfig', '.pkgmeta', 'README.md', 'CHANGELOG.md',
  'LICENSE', 'local_deploy.sh', 'local_deploy.ps1', 'package.json', 'package-lock.json',
]);

function walk(dir, onFile) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      if (IGNORE_DIRS.has(entry.name)) continue;
      walk(join(dir, entry.name), onFile);
    } else {
      if (IGNORE_FILES.has(entry.name)) continue;
      onFile(join(dir, entry.name));
    }
  }
}

function measureStatic() {
  let bytes = 0;
  let luaLines = 0;
  const libDirs = [];

  walk(addonDir, (file) => {
    bytes += statSync(file).size;
    if (file.endsWith('.lua')) {
      luaLines += readFileSync(file, 'utf8').split('\n').length;
    }
  });

  // A bundled library is the single biggest thing separating a light addon from
  // a heavy one, so it is called out by name rather than folded into the size.
  for (const entry of readdirSync(addonDir, { withFileTypes: true })) {
    if (entry.isDirectory() && /^libs?$/i.test(entry.name)) {
      libDirs.push(entry.name);
    }
  }

  return { packagedBytes: bytes, packagedKB: +(bytes / 1024).toFixed(1), luaLines, libDirs };
}

// ---------------------------------------------------------------------------
// Behavioural checks
// ---------------------------------------------------------------------------

async function runCases() {
  const casesDir = join(addonDir, 'perf', 'cases');
  if (!existsSync(casesDir)) return [];

  const files = readdirSync(casesDir).filter((f) => f.endsWith('.lua')).sort();
  if (files.length === 0) return [];

  const { lua, lauxlib, lualib, to_luastring, to_jsstring } = await import('fengari');

  const results = [];
  for (const file of files) {
    const casePath = join(casesDir, file);
    const L = lauxlib.luaL_newstate();
    lualib.luaL_openlibs(L);

    // The case needs to find the shared stubs and its own addon sources. Both
    // are handed over as globals rather than through package.path, so a case
    // never has to know where the harness was checked out to.
    lua.lua_pushstring(L, to_luastring(join(HERE, 'lib').split(sep).join('/')));
    lua.lua_setglobal(L, to_luastring('HARNESS_LIB'));
    lua.lua_pushstring(L, to_luastring(addonDir.split(sep).join('/')));
    lua.lua_setglobal(L, to_luastring('ADDON_DIR'));

    const src = readFileSync(casePath, 'utf8');
    if (lauxlib.luaL_loadbuffer(L, to_luastring(src), null, to_luastring(file)) !== lua.LUA_OK) {
      throw new Error(`${file}: load error: ${to_jsstring(lua.lua_tostring(L, -1))}`);
    }
    if (lua.lua_pcall(L, 0, 1, 0) !== lua.LUA_OK) {
      throw new Error(`${file}: ${to_jsstring(lua.lua_tostring(L, -1))}`);
    }

    // The case returns an array of { name, callsPerFrame, idleCallsPerSecond, ... }.
    const scenarios = [];
    const top = lua.lua_gettop(L);
    if (!lua.lua_istable(L, top)) {
      throw new Error(`${file}: expected the case to return a table of scenarios`);
    }
    const len = lua.lua_rawlen(L, top);
    for (let i = 1; i <= len; i += 1) {
      lua.lua_rawgeti(L, top, i);
      const scenario = {};
      lua.lua_pushnil(L);
      while (lua.lua_next(L, -2) !== 0) {
        const key = to_jsstring(lua.lua_tostring(L, -2));
        scenario[key] = lua.lua_isnumber(L, -1)
          ? lua.lua_tonumber(L, -1)
          : to_jsstring(lua.lua_tostring(L, -1));
        lua.lua_pop(L, 1);
      }
      lua.lua_pop(L, 1);
      scenarios.push(scenario);
    }
    results.push(...scenarios);
  }
  return results;
}

// ---------------------------------------------------------------------------
// Budget enforcement
// ---------------------------------------------------------------------------

function enforce(stat, scenarios) {
  const failures = [];
  const checks = [];

  const check = (label, actual, limit, unit, ok) => {
    checks.push({ label, actual, limit, unit, ok });
    if (!ok) failures.push(`${label}: ${actual}${unit} exceeds budget of ${limit}${unit}`);
  };

  if (budget.maxPackagedKB != null) {
    check('Packaged size', stat.packagedKB, budget.maxPackagedKB, ' KB',
      stat.packagedKB <= budget.maxPackagedKB);
  }

  if (budget.allowBundledLibs === false) {
    const n = stat.libDirs.length;
    checks.push({ label: 'Bundled libraries', actual: n, limit: 0, unit: '', ok: n === 0 });
    if (n !== 0) failures.push(`Bundled libraries: found ${stat.libDirs.join(', ')}`);
  }

  if (scenarios.length > 0) {
    if (budget.maxWidgetCallsPerFrame != null) {
      const worst = Math.max(...scenarios.map((s) => s.callsPerFrame ?? 0));
      check('Widget calls per frame', +worst.toFixed(2), budget.maxWidgetCallsPerFrame, '',
        worst <= budget.maxWidgetCallsPerFrame + 1e-9);
    }
    if (budget.maxIdleCallsPerSecond != null) {
      const worst = Math.max(...scenarios.map((s) => s.idleCallsPerSecond ?? 0));
      check('Widget calls per second while idle', worst, budget.maxIdleCallsPerSecond, '',
        worst <= budget.maxIdleCallsPerSecond);
    }
    // Per-frame is the wrong unit for a timer-driven addon: it does no per-frame
    // work at all, and the honest question is what a tick costs and how often
    // one happens. Scenarios opt in by reporting callsPerSecond.
    if (budget.maxCallsPerSecond != null) {
      const reported = scenarios.filter((s) => s.callsPerSecond != null);
      if (reported.length > 0) {
        const worst = Math.max(...reported.map((s) => s.callsPerSecond));
        check('Widget calls per second', +worst.toFixed(2), budget.maxCallsPerSecond, '',
          worst <= budget.maxCallsPerSecond + 1e-9);
      }
    }
  }

  return { checks, failures };
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

function markdown(stat, scenarios, checks, ok) {
  const lines = [];
  lines.push('<!-- perf:begin -->');
  lines.push('');
  lines.push(ok
    ? '> Measured on every push by the Ultra Performance harness. The build fails if any number here exceeds the budget in `perf/budget.json`.'
    : '> **Budget exceeded.** These numbers are published as measured.');
  lines.push('');
  lines.push('| Check | Measured | Budget | |');
  lines.push('|---|---:|---:|:--:|');
  for (const c of checks) {
    lines.push(`| ${c.label} | ${c.actual}${c.unit} | ${c.limit}${c.unit} | ${c.ok ? 'pass' : 'FAIL'} |`);
  }
  lines.push('');

  if (scenarios.length > 0) {
    const anyPerSecond = scenarios.some((s) => s.callsPerSecond != null);
    lines.push('Scenarios driven against the real addon source, outside the game:');
    lines.push('');
    lines.push(anyPerSecond
      ? '| Scenario | Calls/frame | Calls/sec | Notes |'
      : '| Scenario | Calls/frame | Notes |');
    lines.push(anyPerSecond ? '|---|---:|---:|---|' : '|---|---:|---|');
    for (const s of scenarios) {
      const notes = s.notes ?? '';
      const cpf = s.callsPerFrame != null ? (+s.callsPerFrame).toFixed(2) : '-';
      if (anyPerSecond) {
        const cps = s.callsPerSecond != null ? (+s.callsPerSecond).toFixed(1) : '-';
        lines.push(`| ${s.name} | ${cpf} | ${cps} | ${notes} |`);
      } else {
        lines.push(`| ${s.name} | ${cpf} | ${notes} |`);
      }
    }
    lines.push('');
  }

  lines.push(`<sub>${stat.luaLines.toLocaleString()} lines of Lua · ${stat.packagedKB} KB packaged · `
    + `${stat.libDirs.length === 0 ? 'no bundled libraries' : 'bundles ' + stat.libDirs.join(', ')}</sub>`);
  lines.push('');
  lines.push('<!-- perf:end -->');
  return lines.join('\n');
}

function badge(stat, scenarios, ok) {
  let message;
  if (!ok) {
    message = 'over budget';
  } else if (scenarios.length > 0) {
    const worstFrame = Math.max(...scenarios.map((s) => s.callsPerFrame ?? 0));
    if (worstFrame > 0) {
      const rounded = Math.round(worstFrame * 100) / 100;
      message = `${rounded} call${rounded === 1 ? '' : 's'}/frame`;
    } else {
      const perSecond = scenarios.filter((s) => s.callsPerSecond != null);
      message = perSecond.length > 0
        ? `${Math.round(Math.max(...perSecond.map((s) => s.callsPerSecond)) * 10) / 10} calls/sec`
        : 'no per-frame work';
    }
  } else {
    message = `${stat.packagedKB} KB`;
  }
  return {
    schemaVersion: 1,
    label: 'ultra performance',
    message,
    color: ok ? 'brightgreen' : 'red',
  };
}

// Replace the block between the markers, leaving the rest of the README alone.
function injectReadme(path, block) {
  const body = readFileSync(path, 'utf8');
  const begin = body.indexOf('<!-- perf:begin -->');
  const end = body.indexOf('<!-- perf:end -->');
  if (begin === -1 || end === -1) {
    console.error(`${path} has no <!-- perf:begin --> / <!-- perf:end --> markers; leaving it alone.`);
    return false;
  }
  const updated = body.slice(0, begin) + block + body.slice(end + '<!-- perf:end -->'.length);
  if (updated === body) return false;
  writeFileSync(path, updated);
  return true;
}

// ---------------------------------------------------------------------------

const stat = measureStatic();
const scenarios = await runCases();
const { checks, failures } = enforce(stat, scenarios);
const ok = failures.length === 0;

const report = {
  addon: relative(join(addonDir, '..'), addonDir) || 'addon',
  measuredAt: new Date().toISOString(),
  ok,
  budget,
  static: stat,
  scenarios,
  checks,
  failures,
};

const block = markdown(stat, scenarios, checks, ok);

console.log(block.replace(/<!-- perf:(begin|end) -->/g, '').trim());
console.log('');

if (args.json) writeFileSync(args.json, JSON.stringify(report, null, 2) + '\n');
if (args.markdown) writeFileSync(args.markdown, block + '\n');
if (args.badge) writeFileSync(args.badge, JSON.stringify(badge(stat, scenarios, ok), null, 2) + '\n');
if (args.readme && existsSync(args.readme)) {
  console.log(injectReadme(args.readme, block) ? `Updated ${args.readme}` : `${args.readme} already current`);
}

if (!ok) {
  console.error('\nUltra Performance budget exceeded:');
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}
console.log('Within budget.');
