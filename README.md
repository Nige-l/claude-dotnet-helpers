# claude-dotnet-helpers

.NET build, test, and cleanup tools for Claude Code.

Build projects, run tests, kill orphaned compiler processes, and get structured error reports — all from Claude Code without leaving your conversation.

## Requirements

- **Linux or macOS**
- **[Bun](https://bun.sh)** — the MCP server runs on Bun
- **.NET 8+ SDK** — `dotnet --version` should show 8.x or later
- **jq** — used by the error analysis script

Install jq (Debian/Ubuntu):

```sh
sudo apt install -y jq
```

Install jq (macOS):

```sh
brew install jq
```

## Quick Start

**1. Install the plugin.**

Add the GitHub repo as a marketplace, then install:

```sh
claude plugin marketplace add https://github.com/Nige-l/claude-dotnet-helpers
claude plugin install dotnet-helpers
```

**2. Use the tools.** Ask Claude to build your project, run tests, or clean up orphaned compiler processes.

### Alternative: local install from a clone

```sh
git clone https://github.com/Nige-l/claude-dotnet-helpers.git
claude --plugin-dir ./claude-dotnet-helpers
```

This loads the plugin for a single session without installing it globally.

## Tools

| Tool | Description | Parameters |
|------|-------------|------------|
| `build` | Build a .NET project or solution | `project` (optional path), `configuration` (optional Debug/Release) |
| `test` | Run .NET tests | `project` (required path), `filter` (optional expression), `configuration` (optional Debug/Release) |
| `cleanup` | Kill orphaned dotnet/MSBuild/VBCSCompiler processes | — |
| `analyze_errors` | Parse raw build output into structured error report | `build_output` (required string) |

## Output Examples

### `build`

```json
{
  "success": true,
  "errors": 0,
  "warnings": 2,
  "output": "Build succeeded.\n    2 Warning(s)\n    0 Error(s)"
}
```

### `test`

```json
{
  "passed": 42,
  "failed": 1,
  "skipped": 0,
  "failures": [
    {
      "test": "MyNamespace.MyTest.ShouldReturnTrue",
      "message": "Assert.Equal() Failure\nExpected: True\nActual:   False"
    }
  ]
}
```

### `cleanup`

```json
{
  "killed": ["VBCSCompiler (pid 12345)", "dotnet (pid 67890)"],
  "message": "Killed 2 orphaned dotnet processes."
}
```

### `analyze_errors`

```json
{
  "errors": [
    {
      "file": "src/Game/MySystem.cs",
      "line": 42,
      "code": "CS0103",
      "message": "The name 'foo' does not exist in the current context",
      "hint": "Check for a missing using directive or misspelled variable name."
    }
  ],
  "warnings": 1,
  "error_count": 1
}
```

## Error Categories

The `analyze_errors` tool recognises common error codes and adds a `hint` field:

| Code | Category | Common Cause |
|------|----------|--------------|
| CS0103 | Undefined name | Missing using directive or typo |
| CS0246 | Type not found | Missing reference or using directive |
| CS8177 | ref in async | `ref` local used in an `async` method (not allowed) |
| CS8175 | ref in lambda | `ref` local captured in a lambda (not allowed) |
| CS0161 | Missing return | Not all code paths return a value |
| CS1061 | Member not found | Wrong method name or missing extension |

## License

[MIT](LICENSE)
