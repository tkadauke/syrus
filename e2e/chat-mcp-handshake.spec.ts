import { test, expect } from "@playwright/test"
import { execFileSync } from "node:child_process"
import { createServer } from "node:net"

test("every configured chat provider completes persistent and fallback MCP handshakes", async () => {
  test.skip(Boolean(process.env.E2E_BASE_URL), "The MCP handshake guard runs inside the local ephemeral Rails environment.")

  const port = await availablePort()
  const output = execFileSync("bin/rails", ["runner", "e2e/support/chat_mcp_handshake.rb"], {
    encoding: "utf8",
    env: {
      ...process.env,
      RAILS_ENV: process.env.RAILS_ENV ?? "development",
      SYRUS_MCP_DAEMON_AUTO_START: "1",
      SYRUS_PERSISTENT_MCP_PORT: String(port)
    },
    timeout: 120_000
  })
  const resultLine = output.split("\n").find((line) => line.startsWith("CHAT_MCP_HANDSHAKE="))

  expect(resultLine, output).toBeTruthy()
  const scenarios = JSON.parse(resultLine!.slice("CHAT_MCP_HANDSHAKE=".length))
  expect(Object.keys(scenarios).sort()).toEqual(["fallback", "persistent"])
  for (const providers of Object.values(scenarios) as Array<Record<string, Record<string, { tools: number; transport: string }>>>) {
    expect(Object.keys(providers).length).toBeGreaterThan(0)
    for (const servers of Object.values(providers)) {
      expect(Object.keys(servers).length).toBeGreaterThan(0)
      for (const server of Object.values(servers)) expect(server.tools).toBeGreaterThan(0)
    }
  }
  for (const server of Object.values(scenarios.persistent.claude) as Array<{ transport: string }>) {
    expect(server.transport).toBe("http")
  }
  for (const [provider, servers] of Object.entries(scenarios.persistent) as Array<[string, Record<string, { transport: string }>]>) {
    if (provider === "claude") continue
    for (const server of Object.values(servers)) expect(server.transport).toBe("stdio")
  }
  for (const servers of Object.values(scenarios.fallback) as Array<Record<string, { transport: string }>>) {
    for (const server of Object.values(servers)) expect(server.transport).toBe("stdio")
  }
})

function availablePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer()
    server.once("error", reject)
    server.listen(0, "127.0.0.1", () => {
      const address = server.address()
      if (!address || typeof address === "string") return reject(new Error("Could not allocate an MCP daemon port"))
      server.close((error) => (error ? reject(error) : resolve(address.port)))
    })
  })
}
