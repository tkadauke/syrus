import { describe, expect, it } from "vitest"
import { slashCommands, type SlashCommand } from "./slashCommands"

function promptFor(commandName: string, args = "") {
  const command: SlashCommand | undefined = slashCommands.find((item) => item.name === commandName)
  if (!command?.toPrompt) throw new Error(`Missing toPrompt for ${commandName}`)

  return command.toPrompt(args)
}

describe("slashCommands", () => {
  it("builds read-only MCP prompts for Job and Epic commands", () => {
    expect(promptFor("/jobs", "open")).toContain("Call the `list_jobs` MCP tool")
    expect(promptFor("/jobs", "open")).toContain('Pass this operator filter through when choosing tool arguments: "open".')
    expect(promptFor("/job", "1092")).toContain('Call the `read_job` MCP tool for Job id "1092".')
    expect(promptFor("/epic", "94")).toContain('Call the `read_epic` MCP tool for Epic id "94".')
  })

  it("builds read-only MCP prompts for repository triage and context commands", () => {
    expect(promptFor("/prs")).toContain("Call the `list_open_prs` MCP tool")
    expect(promptFor("/issues")).toContain("Call the `list_open_issues` MCP tool")
    expect(promptFor("/proposals")).toContain("Call the `list_proposals` MCP tool")
    expect(promptFor("/canvas")).toContain("Call the `read_scene` MCP tool")
  })

  it("builds a topic bookmark prompt with the provided label", () => {
    expect(promptFor("/bookmark", "Launch plan")).toContain('Call the `set_bookmark` MCP tool with label "Launch plan" and kind "topic".')
  })
})
