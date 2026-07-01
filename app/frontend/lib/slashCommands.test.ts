import { describe, expect, it } from "vitest"
import { findSlashCommand, slashCommandPrompt, slashCommandSignature, slashCommands, type SlashCommand } from "./slashCommands"

function promptFor(commandName: string, args = "") {
  const command: SlashCommand | undefined = slashCommands.find((item) => item.name === commandName)
  if (!command?.toPrompt) throw new Error(`Missing toPrompt for ${commandName}`)

  return command.toPrompt(args)
}

describe("slashCommands", () => {
  const reclassifiedSystemCommands = [
    "/jobs",
    "/job",
    "/epic",
    "/prs",
    "/issues",
    "/proposals",
    "/bookmark",
    "/discard",
    "/cancel",
    "/retry",
    "/clear-canvas"
  ]

  it("registers /propose as a guided wizard skill command", () => {
    const match = findSlashCommand("/propose")

    expect(match?.command.kind).toBe("skill")
    expect(match?.command.description).toBe("Start a guided Job proposal wizard")
    expect(match?.command.args).toEqual([])
    expect(match ? slashCommandSignature(match.command) : "missing").toBe("")
  })

  it("classifies direct client commands as system commands without prompts", () => {
    for (const commandName of reclassifiedSystemCommands) {
      const command = slashCommands.find((item) => item.name === commandName)
      expect(command?.kind).toBe("system")
      expect(command).not.toHaveProperty("toPrompt")
    }
  })

  it("keeps agent-backed commands as skill commands", () => {
    for (const commandName of ["/propose", "/feedback", "/canvas"]) {
      expect(slashCommands.find((item) => item.name === commandName)?.kind).toBe("skill")
    }

    expect(promptFor("/canvas")).toContain("Call the `read_scene` MCP tool")
  })

  it("transforms /propose into the Job proposal wizard prompt", () => {
    const prompt = slashCommandPrompt("/propose")

    expect(prompt).toContain("Start the guided Job proposal wizard.")
    expect(prompt).toContain("Job title")
    expect(prompt).toContain("Job description")
    expect(prompt).toContain("Optional Epic")
    expect(prompt).toContain("call the propose_job tool")
  })

  it("preserves optional context after /propose", () => {
    const prompt = slashCommandPrompt("/propose payments cleanup")

    expect(prompt).toContain("initial context")
    expect(prompt).toContain("payments cleanup")
  })

  it("leaves other skill commands unchanged", () => {
    expect(slashCommandPrompt("hello")).toBe("hello")
  })
})
