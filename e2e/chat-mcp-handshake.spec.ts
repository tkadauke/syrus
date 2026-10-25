import { test, expect } from "@playwright/test"
import { execFileSync } from "node:child_process"

test("every configured chat provider completes an MCP handshake and returns tools", () => {
  test.skip(Boolean(process.env.E2E_BASE_URL), "The MCP handshake guard runs inside the local ephemeral Rails environment.")

  const output = execFileSync("bin/rails", ["runner", "e2e/support/chat_mcp_handshake.rb"], {
    encoding: "utf8",
    env: { ...process.env, RAILS_ENV: process.env.RAILS_ENV ?? "development" },
    timeout: 120_000
  })
  const resultLine = output.split("\n").find((line) => line.startsWith("CHAT_MCP_HANDSHAKE="))

  expect(resultLine, output).toBeTruthy()
  const providers = JSON.parse(resultLine!.slice("CHAT_MCP_HANDSHAKE=".length))
  expect(Object.keys(providers).length).toBeGreaterThan(0)
  for (const servers of Object.values(providers) as Array<Record<string, { tools: number }>>) {
    expect(Object.keys(servers).length).toBeGreaterThan(0)
    for (const server of Object.values(servers)) expect(server.tools).toBeGreaterThan(0)
  }
})
