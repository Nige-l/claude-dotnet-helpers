---
name: cleanup
description: Kill orphaned VBCSCompiler and MSBuild processes to reclaim memory. Use when builds are slow, memory is high, or after a heavy build wave.
user-invocable: true
allowed-tools: [Bash, Read]
---

# /dotnet-helpers:cleanup

Kill orphaned .NET compiler processes using the `cleanup` MCP tool and report what was reclaimed.

## Steps

### 1. Run the cleanup MCP tool

Call the `cleanup` MCP tool with no additional parameters:

- Tool: `cleanup`
- Input: `{}`

Wait for the result.

### 2. Report what was killed

Present the output clearly:

- List each process that was killed (name + PID if available).
- Report the total estimated memory reclaimed (e.g., "freed ~380 MB").
- If nothing was killed, report that no orphaned processes were found — this is a good outcome.

### 3. Advise on when to run cleanup

Suggest running cleanup proactively in these situations:

- **Before a build** on a resource-constrained machine (under 8 GB RAM, integrated graphics) — stale VBCSCompiler instances from previous sessions accumulate ~100–400 MB each.
- **After a failed build** that was cancelled mid-way — MSBuild child processes may not exit cleanly.
- **Between heavy build waves** in a long session — each `dotnet build` invocation can leave a VBCSCompiler daemon running if not already running.
- **When the machine feels sluggish** during development — orphaned compilers are a common culprit.

Running cleanup is always safe — if no orphans exist, it exits cleanly with nothing to do.
