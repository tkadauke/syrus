import { describe, expect, it } from "vitest"
import { filterSlashCommands, findSlashCommand, slashCommandDescription, slashCommandPrompt, slashCommandSignature, slashCommands, type SlashCommand } from "./slashCommands"

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
    "/queue",
    "/spend",
    "/proposals",
    "/branch",
    "/pin",
    "/bookmark",
    "/discard",
    "/cancel",
    "/retry",
    "/review",
    "/clear-canvas",
    "/approve",
    "/schedule"
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

  it("registers /queue as a no-argument system command", () => {
    const match = findSlashCommand("/queue")

    expect(match?.command.kind).toBe("system")
    expect(match?.command.description).toBe("Open the landing queue.")
    expect(match?.command.args).toEqual([])
    expect(match ? slashCommandSignature(match.command) : "missing").toBe("")
  })

  it("registers /spend as a no-argument system command", () => {
    const match = findSlashCommand("/spend")

    expect(match?.command.kind).toBe("system")
    expect(match?.command.description).toBe("Open spending insights.")
    expect(match?.command.args).toEqual([])
    expect(match ? slashCommandSignature(match.command) : "missing").toBe("")
  })

  it("registers /share as a no-argument system command", () => {
    const match = findSlashCommand("/share")

    expect(match?.command.kind).toBe("system")
    expect(match?.command.description).toBe("Copy a shareable link to this chat")
    expect(match?.command.args).toEqual([])
    expect(match ? slashCommandSignature(match.command) : "missing").toBe("")
  })

  it("registers /schedule with optional time and message args", () => {
    const match = findSlashCommand("/schedule 2h check the queue")

    expect(match?.command.kind).toBe("system")
    expect(match?.command.description).toBe("Schedule a chat message to send later.")
    expect(match?.command.args).toEqual([{ name: "time", required: false }, { name: "message", required: false }])
    expect(match?.argsText).toBe("2h check the queue")
    expect(match ? slashCommandSignature(match.command) : "missing").toBe("[time] [message]")
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

  it("hides proposal and repository attachment commands for supervisor chats", () => {
    const context = { chat: { system_kind: "supervisor" } }

    expect(filterSlashCommands("", context).map((command) => command.name)).not.toEqual(expect.arrayContaining([
      "/attach",
      "/proposals",
      "/discard",
      "/feedback",
      "/propose"
    ]))
    expect(findSlashCommand("/propose", context)).toBeNull()
    expect(slashCommandPrompt("/propose", context)).toBe("/propose")
  })

  it("keeps proposal and repository attachment commands for ordinary chats", () => {
    const context = { chat: { system_kind: null } }

    expect(filterSlashCommands("", context).map((command) => command.name)).toEqual(expect.arrayContaining([
      "/attach",
      "/proposals",
      "/discard",
      "/feedback",
      "/propose"
    ]))
    expect(findSlashCommand("/propose", context)?.command.name).toBe("/propose")
    expect(slashCommandPrompt("/propose", context)).toContain("call the propose_job tool")
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

  it("registers /review as a system command with an optional id arg", () => {
    const match = findSlashCommand("/review")

    expect(match?.command.kind).toBe("system")
    expect(match?.command.args).toEqual([{ name: "id", required: false }])
    expect(match?.command.requiresConfirmation).toBeFalsy()
    expect(match?.command.description).toBe("Open a Job's pull request in a new tab.")
    expect(match ? slashCommandSignature(match.command) : "missing").toBe("[id]")
  })

  it("registers /approve with an optional id arg and requiresConfirmation", () => {
    const match = findSlashCommand("/approve")

    expect(match?.command.kind).toBe("system")
    expect(match?.command.args).toEqual([{ name: "id", required: false }])
    expect(match?.command.requiresConfirmation).toBe(true)
    expect(match?.command.description).toBe("Approve a Job for landing.")
    expect(match ? slashCommandSignature(match.command) : "missing").toBe("[id]")
  })

  it("registers /diff as a skill command with an optional id arg", () => {
    const match = findSlashCommand("/diff")

    expect(match?.command.kind).toBe("skill")
    expect(match?.command.description).toBe("Show the diff for a Job's PR inline.")
    expect(match?.command.args).toEqual([{ name: "id", required: false }])
    expect(match ? slashCommandSignature(match.command) : "missing").toBe("[id]")
  })

  it("builds a direct get_job_diff prompt when an id is provided to /diff", () => {
    expect(slashCommandPrompt("/diff 42")).toContain("get_job_diff")
    expect(slashCommandPrompt("/diff 42")).toContain("42")
    expect(slashCommandPrompt("/diff JOB-123")).toContain("JOB-123")
    expect(slashCommandPrompt("/diff job-7")).toContain("job-7")
  })

  it("builds an ask-first prompt when /diff is used without an id", () => {
    const prompt = slashCommandPrompt("/diff")

    expect(prompt).toContain("get_job_diff")
    expect(prompt).toContain("Ask the operator")
  })

  it("registers /remind as a skill command with an optional message arg", () => {
    const match = findSlashCommand("/remind")

    expect(match?.command.kind).toBe("skill")
    expect(match?.command.description).toBe("Ask the agent to set a reminder.")
    expect(match?.command.args).toEqual([{ name: "message", required: false }])
    expect(match ? slashCommandSignature(match.command) : "missing").toBe("[message]")
  })

  it("transforms /remind without args into a prompt ending with a period", () => {
    const prompt = slashCommandPrompt("/remind")

    expect(prompt).toContain("The operator wants to set a reminder.")
    expect(prompt).toContain("schedule_wakeup MCP tool")
    expect(prompt).toContain("Confirm the wakeup time")
  })

  it("includes the message in the /remind prompt when provided", () => {
    const prompt = slashCommandPrompt("/remind tomorrow at 9am standup")

    expect(prompt).toContain("The operator wants to set a reminder: tomorrow at 9am standup")
    expect(prompt).toContain("schedule_wakeup MCP tool")
  })
})
