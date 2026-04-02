---
name: setup
description: Guide setup of dotnet-helpers dependencies — check .NET 8+, jq, bun, detect package manager and install missing deps. Use when user asks to install or configure the dotnet-helpers tool, or when dependencies are missing.
user-invocable: true
allowed-tools: [Bash, Read]
---

# /dotnet-helpers:setup

Guide the user through installing dependencies for the dotnet-helpers MCP plugin.

## Steps

### 1. Check .NET SDK version

```bash
dotnet --version
```

- If **8.x or higher**: .NET is present and compatible. Proceed.
- If **lower than 8.x**: .NET needs upgrading. Advise the user to install .NET 8 SDK from https://dotnet.microsoft.com/download.
- If **not found**: .NET is not installed at all. Advise installation before continuing.

### 2. Check jq

```bash
command -v jq && jq --version
```

- **jq** is required for structured JSON output parsing in the MCP tool responses.
- If missing, note it for installation in step 4.

### 3. Check bun

```bash
command -v bun && bun --version
```

- **bun** is the runtime used to execute the MCP server (`server.ts`).
- If missing, note it for installation in step 4.

### 4. Detect package manager and install missing deps

Check which package manager is available and install any missing tools:

| Distro | Check | Install command |
|--------|-------|----------------|
| Debian/Ubuntu | `command -v apt` | `sudo apt update && sudo apt install -y jq` |
| Fedora | `command -v dnf` | `sudo dnf install -y jq` |
| Arch | `command -v pacman` | `sudo pacman -S --noconfirm jq` |
| openSUSE | `command -v zypper` | `sudo zypper install -y jq` |

For **bun**, the install is distro-independent:

```bash
curl -fsSL https://bun.sh/install | bash
```

Only include missing packages in the install command. Tell the user the exact command and ask for confirmation before running it (since package installs may require sudo).

### 5. Verify installation

After installation, re-run the checks from steps 1–3 to confirm all dependencies are present. If all required deps are found, report success.

If any dep is still missing, report which one failed and what the error was.
