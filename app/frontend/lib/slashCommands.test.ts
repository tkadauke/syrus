import { describe, expect, it } from "vitest"
import { findSlashCommand, slashCommandDescription, slashCommandPrompt, slashCommandSignature, slashCommands, type SlashCommand } from "./slashCommands"

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
    "/branch",
    "/pin",
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

  it("registers /branch as a no-argument system command", () => {
    const match = findSlashCommand("/branch")

    expect(match?.command.kind).toBe("system")
    expect(match?.command.description).toBe("Start a new chat branched from this point")
    expect(match?.command.args).toEqual([])
    expect(match ? slashCommandSignature(match.command) : "missing").toBe("")
  })

  it("registers /copy as a system command without args", () => {
    const match = findSlashCommand("/copy")

    expect(match?.command.kind).toBe("system")
    expect(match?.command.description).toBe("Copy last response to clipboard")
    expect(match?.command.args).toEqual([])
    expect(match ? slashCommandSignature(match.command) : "missing").toBe("")
  })

  it("registers /search as a system command with an optional query", () => {
    const match = findSlashCommand("/search deployment notes")

    expect(match?.command.kind).toBe("system")
    expect(match?.command.description).toBe("Find and open another chat")
    expect(match?.command.args).toEqual([{ name: "query", required: false }])
    expect(match?.argsText).toBe("deployment notes")
    expect(match ? slashCommandSignature(match.command) : "missing").toBe("[query]")
  })

  it("describes /pin from the current chat pinned state", () => {
    const match = findSlashCommand("/pin")

    expect(match?.command.kind).toBe("system")
    expect(match ? slashCommandDescription(match.command, { chat: { pinned: false } }) : "missing").toBe("Pin this chat to the top of the sidebar")
    expect(match ? slashCommandDescription(match.command, { chat: { pinned: true } }) : "missing").toBe("Unpin this chat")
  })

  it("registers /share as a no-argument system command", () => {
    const match = findSlashCommand("/share")

    expect(match?.command.kind).toBe("system")
    expect(match?.command.description).toBe("Copy a shareable link to this chat")
    expect(match?.command.args).toEqual([])
    expect(match ? slashCommandSignature(match.command) : "missing").toBe("")
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

  it("registers /job with an optional id arg", () => {
    const match = findSlashCommand("/job")

    expect(match?.command.kind).toBe("system")
    expect(match?.command.args).toEqual([{ name: "id", required: false }])
    expect(match ? slashCommandSignature(match.command) : "missing").toBe("[id]")
  })

  it("registers /epic with an optional id arg", () => {
    const match = findSlashCommand("/epic")

    expect(match?.command.kind).toBe("system")
    expect(match?.command.args).toEqual([{ name: "id", required: false }])
    expect(match ? slashCommandSignature(match.command) : "missing").toBe("[id]")
  })

  it("registers /cancel with an optional id arg and requiresConfirmation", () => {
    const match = findSlashCommand("/cancel")

    expect(match?.command.kind).toBe("system")
    expect(match?.command.args).toEqual([{ name: "id", required: false }])
    expect(match?.command.requiresConfirmation).toBe(true)
    expect(match ? slashCommandSignature(match.command) : "missing").toBe("[id]")
  })

  it("registers /retry with an optional id arg and requiresConfirmation", () => {
    const match = findSlashCommand("/retry")

    expect(match?.command.kind).toBe("system")
    expect(match?.command.args).toEqual([{ name: "id", required: false }])
    expect(match?.command.requiresConfirmation).toBe(true)
    expect(match ? slashCommandSignature(match.command) : "missing").toBe("[id]")
  })

  it("registers /feedback with an optional id arg and requiresConfirmation", () => {
    const match = findSlashCommand("/feedback")

    expect(match?.command.kind).toBe("skill")
    expect(match?.command.args).toEqual([{ name: "id", required: false }])
    expect(match?.command.requiresConfirmation).toBe(true)
    expect(match ? slashCommandSignature(match.command) : "missing").toBe("[id]")
  })
})
