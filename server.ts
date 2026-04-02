#!/usr/bin/env bun
/**
 * .NET Helpers MCP server for Claude Code.
 *
 * Exposes dotnet build, test, cleanup, and error-analysis tools
 * by dispatching to scripts in bin/. Designed to run under Bun
 * with the MCP SDK's stdio transport.
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from '@modelcontextprotocol/sdk/types.js'
import { fileURLToPath } from 'url'
import { dirname, join } from 'path'
import { writeFile, unlink } from 'fs/promises'
import { tmpdir } from 'os'
import { randomBytes } from 'crypto'

const __dirname = dirname(fileURLToPath(import.meta.url))
const SCRIPT = join(__dirname, 'bin', 'dotnet-helpers.sh')

// Last-resort safety net — log and keep serving on unhandled errors.
process.on('unhandledRejection', err => {
  process.stderr.write(`dotnet-helpers: unhandled rejection: ${err}\n`)
})
process.on('uncaughtException', err => {
  process.stderr.write(`dotnet-helpers: uncaught exception: ${err}\n`)
})

// ---------------------------------------------------------------------------
// Helper: run a script and capture output
// ---------------------------------------------------------------------------

const SCRIPT_TIMEOUT_MS = 30_000

async function runScript(
  args: string[],
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const proc = Bun.spawn(['bash', SCRIPT, ...args], {
    stdout: 'pipe',
    stderr: 'pipe',
    env: { ...process.env },
  })

  let timeoutId: ReturnType<typeof setTimeout>
  const timeout = new Promise<never>((_, reject) => {
    timeoutId = setTimeout(() => {
      proc.kill()
      reject(new Error(`Script timed out after ${SCRIPT_TIMEOUT_MS / 1000}s`))
    }, SCRIPT_TIMEOUT_MS)
  })

  let result: [string, string, number]
  try {
    result = await Promise.race([
      Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited,
      ]),
      timeout,
    ])
  } catch (err) {
    clearTimeout(timeoutId!)
    throw err
  }
  clearTimeout(timeoutId!)
  const [stdout, stderr, exitCode] = result

  return { stdout: stdout.trim(), stderr: stderr.trim(), exitCode }
}

// ---------------------------------------------------------------------------
// MCP Server
// ---------------------------------------------------------------------------

const server = new Server(
  { name: 'dotnet-helpers', version: '0.1.0' },
  { capabilities: { tools: {} } },
)

// ---------------------------------------------------------------------------
// ListTools
// ---------------------------------------------------------------------------

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'build',
      description:
        'Build a .NET project or solution. Runs `dotnet build` and returns structured output with error/warning counts and full compiler output.',
      inputSchema: {
        type: 'object' as const,
        properties: {
          project: {
            type: 'string',
            description:
              'Path to the .csproj, .sln, or directory to build. Omit to build the solution in the current directory.',
          },
          configuration: {
            type: 'string',
            description: 'Build configuration: Debug or Release. Default: Debug.',
          },
        },
        required: ['project'],
      },
    },
    {
      name: 'test',
      description:
        'Run .NET tests for a project. Runs `dotnet test` and returns pass/fail counts and failure details. Note: runs with --no-build. Run the build tool first, or the project must already be compiled.',
      inputSchema: {
        type: 'object' as const,
        properties: {
          project: {
            type: 'string',
            description: 'Path to the test .csproj or directory containing tests.',
          },
          filter: {
            type: 'string',
            description:
              'Test filter expression (e.g. "FullyQualifiedName~MyTest" or "Category=Unit"). Omit to run all tests.',
          },
          configuration: {
            type: 'string',
            description: 'Build configuration: Debug or Release. Default: Debug.',
          },
        },
        required: ['project'],
      },
    },
    {
      name: 'cleanup',
      description:
        'Kill orphaned dotnet build and compiler processes (VBCSCompiler, MSBuild, dotnet) that accumulate after repeated builds. Run between build waves to reclaim memory.',
      inputSchema: {
        type: 'object' as const,
        properties: {},
      },
    },
    {
      name: 'analyze_errors',
      description:
        'Parse raw `dotnet build` or `dotnet test` output and return a structured JSON report: error list with file/line/code/message, warning count, and suggested fixes for common error codes.',
      inputSchema: {
        type: 'object' as const,
        properties: {
          build_output: {
            type: 'string',
            description: 'Raw stdout/stderr from a dotnet build or test run.',
          },
        },
        required: ['build_output'],
      },
    },
  ],
}))

// ---------------------------------------------------------------------------
// CallTool
// ---------------------------------------------------------------------------

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params

  try {
    switch (name) {
      case 'build': {
        // Input validation
        if (args?.project !== undefined && typeof args.project !== 'string') {
          return { content: [{ type: 'text', text: 'build: project must be a string' }], isError: true }
        }
        if (args?.project && /[$`|&;<>]/.test(args.project as string)) {
          return { content: [{ type: 'text', text: 'build: project path contains invalid shell metacharacters' }], isError: true }
        }
        if (args?.configuration !== undefined && typeof args.configuration !== 'string') {
          return { content: [{ type: 'text', text: 'build: configuration must be a string' }], isError: true }
        }
        const validConfigs = ['Debug', 'Release']
        if (args?.configuration && !validConfigs.includes(args.configuration as string)) {
          return { content: [{ type: 'text', text: `build: configuration must be one of: ${validConfigs.join(', ')}` }], isError: true }
        }

        const cmdArgs: string[] = ['build', '--json']
        if (args?.project) cmdArgs.push('--project', String(args.project))
        if (args?.configuration) cmdArgs.push('--configuration', String(args.configuration))

        return formatResult(await runScript(cmdArgs))
      }

      case 'test': {
        // Input validation
        if (typeof args?.project !== 'string' || args.project === '') {
          return { content: [{ type: 'text', text: 'test: project is required and must be a non-empty string' }], isError: true }
        }
        if (/[$`|&;<>]/.test(args.project as string)) {
          return { content: [{ type: 'text', text: 'test: project path contains invalid shell metacharacters' }], isError: true }
        }
        if (args?.filter !== undefined && typeof args.filter !== 'string') {
          return { content: [{ type: 'text', text: 'test: filter must be a string' }], isError: true }
        }
        if (args?.filter && /[$`|&;<>]/.test(args.filter as string)) {
          return { content: [{ type: 'text', text: 'test: filter contains invalid shell metacharacters' }], isError: true }
        }
        if (args?.configuration !== undefined && typeof args.configuration !== 'string') {
          return { content: [{ type: 'text', text: 'test: configuration must be a string' }], isError: true }
        }
        const validConfigs = ['Debug', 'Release']
        if (args?.configuration && !validConfigs.includes(args.configuration as string)) {
          return { content: [{ type: 'text', text: `test: configuration must be one of: ${validConfigs.join(', ')}` }], isError: true }
        }

        const cmdArgs: string[] = ['test', '--project', String(args.project), '--json']
        if (args?.filter) cmdArgs.push('--filter', String(args.filter))
        if (args?.configuration) cmdArgs.push('--configuration', String(args.configuration))

        return formatResult(await runScript(cmdArgs))
      }

      case 'cleanup': {
        return formatResult(await runScript(['cleanup', '--json']))
      }

      case 'analyze_errors': {
        // Input validation
        if (typeof args?.build_output !== 'string' || args.build_output === '') {
          return { content: [{ type: 'text', text: 'analyze_errors: build_output is required and must be a non-empty string' }], isError: true }
        }

        // Write build output to a temp file, pass path to script, clean up after
        const tmpFile = join(tmpdir(), `dotnet-helpers-${randomBytes(8).toString('hex')}.txt`)
        try {
          await writeFile(tmpFile, String(args.build_output), 'utf8')
          const result = await runScript(['analyze-errors', tmpFile, '--json'])
          return formatResult(result)
        } finally {
          await unlink(tmpFile).catch(() => {})
        }
      }

      default:
        return { content: [{ type: 'text', text: `Unknown tool: ${name}` }], isError: true }
    }
  } catch (err: any) {
    const msg = err?.message ?? String(err)
    return {
      content: [{ type: 'text', text: `Error running ${name}: ${msg}` }],
      isError: true,
    }
  }
})

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function formatResult(result: { stdout: string; stderr: string; exitCode: number }) {
  const text = result.stdout || result.stderr || 'Command failed'
  return { content: [{ type: 'text' as const, text }], isError: result.exitCode !== 0 }
}

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

const transport = new StdioServerTransport()
await server.connect(transport)
