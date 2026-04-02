---
name: test
description: Run .NET tests and get structured pass/fail results. Use when the user wants to run tests for a project and understand any failures.
user-invocable: true
allowed-tools: [Bash, Read]
---

# /dotnet-helpers:test

Run .NET tests using the `test` MCP tool and present structured pass/fail results with fix suggestions for common failures.

## Steps

### 1. Find the test project

If the user has not specified a path, scan the current directory for test projects:

```bash
find . -maxdepth 4 \( -name "*Tests.csproj" -o -name "*Test.csproj" -o -name "*.Tests.csproj" -o -name "*.Test.csproj" \) | sort
```

- If exactly one test project is found, proceed with it.
- If multiple test projects are found, ask the user which one(s) to run, or offer to run all.
- If no test projects are found, look for any `.csproj` referencing `xunit`, `nunit`, or `mstest` via a quick grep:

```bash
grep -rl "xunit\|nunit\|MSTest" --include="*.csproj" . 2>/dev/null | sort
```

### 2. Run the test MCP tool

Call the `test` MCP tool with the resolved project path:

- Tool: `test`
- Input: `{ "project": "<path to test .csproj>" }`

Wait for the result.

### 3. Present the results

**On all-pass:**

Report the total number of tests that passed. Mention test duration if available.

**On failures:**

For each failing test, show:
- Test name (fully qualified if possible)
- Failure message
- File path and line number of the assertion that failed

Group failures by category if there are many:

| Category | Signs |
|----------|-------|
| Assertion failures | `Assert.Equal`, `Assert.True` failed — logic bug in production code or wrong expected value |
| Null reference | `NullReferenceException` — missing setup, missing dependency injection, or unchecked null |
| Setup / teardown | Fails in constructor or `IAsyncLifetime.InitializeAsync` — configuration or DB issue |
| Timeout | Test hung — likely a deadlock, infinite loop, or waiting on a resource that never becomes available |
| Missing dependency | `InvalidOperationException` about unregistered service — DI container not fully configured in test |

### 4. Suggest fixes for common failures

After presenting the categorized failures, offer targeted suggestions:

- **Assertion failures:** Check the expected value — did the implementation change? Is the test asserting the wrong thing?
- **Null reference in test:** Add null checks or ensure test fixtures initialize all required objects.
- **Setup failures:** Verify the test project can connect to required services (DB, Redis). Check environment variables.
- **Timeouts:** Add a timeout attribute with a reasonable limit and check for blocking calls without `await`.
- **Missing dependency:** Register the service in the test's DI setup or use a mock.

If the same fix applies to multiple failures, group them — don't repeat the same advice per test.
