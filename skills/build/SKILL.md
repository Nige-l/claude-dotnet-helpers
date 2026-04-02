---
name: build
description: Build a .NET project and get structured error analysis with fix-order recommendations. Use when the user wants to build a .sln or .csproj and understand any errors.
user-invocable: true
allowed-tools: [Bash, Read]
---

# /dotnet-helpers:build

Build a .NET project using the `build` MCP tool and present categorized errors with fix-order recommendations.

## Steps

### 1. Find the project to build

If the user has not specified a path, scan the current directory for buildable files:

```bash
find . -maxdepth 3 \( -name "*.sln" -o -name "*.csproj" \) | sort
```

- Prefer a `.sln` over individual `.csproj` files — it builds all projects in the solution together.
- If multiple solutions are found, ask the user which one to build.
- If only `.csproj` files are found with no `.sln`, ask whether to build a specific project or all of them.

### 2. Run the build MCP tool

Call the `build` MCP tool with the resolved project path:

- Tool: `build`
- Input: `{ "project": "<path to .sln or .csproj>" }`

Wait for the result.

### 3. Present the results

**On success (0 errors):**

Report a clean build. Include the project path and any warnings count.

**On failure (errors present):**

Categorize errors into groups for easier scanning:

| Category | Examples |
|----------|---------|
| Missing references | `CS0246`, `CS0234` — type/namespace not found |
| Type mismatches | `CS0029`, `CS0266` — cannot implicitly convert |
| Missing members | `CS1061` — does not contain a definition |
| Syntax errors | `CS1002`, `CS1003`, `CS1519` — unexpected token, expected semicolon |
| Nullability | `CS8600`, `CS8602`, `CS8603` — nullable reference warnings promoted to errors |
| Access modifiers | `CS0122` — inaccessible due to protection level |
| Other | Anything not matching above categories |

**Fix-order recommendations:**

1. Fix **missing references** first — they cascade and cause many false errors in other categories.
2. Fix **syntax errors** next — they prevent the parser from understanding surrounding code.
3. Fix **type mismatches** and **missing members** after references are resolved.
4. Fix **nullability** and **access modifier** errors last.

Show the file path and line number for each error so the user can navigate to them directly.

### 4. If build succeeds after a previous failure

Confirm the fix worked and the build is now clean. Report the total error count reduction (e.g., "was 12 errors, now 0").
