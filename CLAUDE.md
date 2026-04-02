# .NET Helpers Plugin

.NET build, test, and cleanup tools for Claude Code. Four tools available.

## Tool quick reference

| Tool | Purpose |
|------|---------|
| `build` | Build a .NET project/solution — returns error/warning counts and compiler output |
| `test` | Run .NET tests — returns pass/fail counts and failure details |
| `cleanup` | Kill orphaned VBCSCompiler/MSBuild/dotnet processes that accumulate between builds |
| `analyze_errors` | Parse raw build output into structured JSON with file/line/code/message and fix hints |

## Usage notes

- **`build`**: `project` defaults to the current directory if omitted. Accepts `.csproj`, `.sln`, or a directory path.
- **`test`**: `project` is required. Use `filter` to target specific tests (e.g. `"FullyQualifiedName~MyTest"`).
- **`cleanup`**: Run between heavy build waves. Kills `VBCSCompiler`, `MSBuild`, and idle `dotnet` processes. No params needed.
- **`analyze_errors`**: Paste the full stdout+stderr from a failed build into `build_output`. Returns a JSON error list with hints for common codes (CS8177, CS8175, CS0246, etc.).

## Requirements

Linux or macOS, Bun, .NET 8+ SDK, jq.
