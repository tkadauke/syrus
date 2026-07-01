export type SlashCommandKind = "system" | "skill"

export type SlashCommandArg = {
  name: string
  required?: boolean
}

export type SlashCommand = {
  name: `/${string}`
  kind: SlashCommandKind
  args: SlashCommandArg[]
  description: string
  toPrompt?: (args: string) => string
  requiresConfirmation?: boolean
}

export type SlashCommandMatch = {
  command: SlashCommand
  token: string
  argsText: string
}

export const slashCommands = [
  { name: "/rename", kind: "system", args: [{ name: "title", required: true }], description: "Rename the current chat." },
  { name: "/clear", kind: "system", args: [], description: "Clear this chat's message history." },
  { name: "/new", kind: "system", args: [], description: "Start a new chat." },
  { name: "/bookmarks", kind: "system", args: [], description: "Show saved bookmarks in this chat." },
  { name: "/attach", kind: "system", args: [{ name: "owner/repo", required: false }], description: "Attach a repository or open attachment controls." },
  { name: "/settings", kind: "system", args: [], description: "Open chat settings." },
  { name: "/copy", kind: "system", args: [], description: "Copy last response to clipboard" },
  { name: "/search", kind: "system", args: [{ name: "query", required: false }], description: "Find and open another chat" },
  {
    name: "/jobs",
    kind: "system",
    args: [{ name: "filter", required: false }],
    description: "Open Jobs."
  },
  {
    name: "/job",
    kind: "system",
    args: [{ name: "id", required: true }],
    description: "Open a Job."
  },
  {
    name: "/epic",
    kind: "system",
    args: [{ name: "id", required: true }],
    description: "Open an Epic."
  },
  {
    name: "/prs",
    kind: "system",
    args: [],
    description: "Open pull requests for the current repository."
  },
  {
    name: "/issues",
    kind: "system",
    args: [],
    description: "Open GitHub issues for the current repository."
  },
  {
    name: "/proposals",
    kind: "system",
    args: [],
    description: "Jump to proposed work in this chat."
  },
  {
    name: "/canvas",
    kind: "skill",
    args: [],
    description: "Ask the agent to describe the whiteboard.",
    toPrompt: () => "Call the `read_scene` MCP tool and describe the current whiteboard contents, including notable shapes, text, connections, frames, and empty-state if there is nothing on the canvas."
  },
  {
    name: "/bookmark",
    kind: "system",
    args: [{ name: "label", required: true }],
    description: "Bookmark this chat topic."
  },
  { name: "/discard", kind: "system", args: [{ name: "slug", required: true }], description: "Discard proposed work.", requiresConfirmation: true },
  { name: "/cancel", kind: "system", args: [{ name: "id", required: true }], description: "Cancel work.", requiresConfirmation: true },
  { name: "/retry", kind: "system", args: [{ name: "id", required: true }], description: "Retry failed work.", requiresConfirmation: true },
  { name: "/feedback", kind: "skill", args: [{ name: "id", required: true }], description: "Send feedback for the agent to address.", requiresConfirmation: true },
  { name: "/clear-canvas", kind: "system", args: [], description: "Clear the whiteboard.", requiresConfirmation: true },
  {
    name: "/propose",
    kind: "skill",
    args: [],
    description: "Start a guided Job proposal wizard",
    toPrompt: proposeWizardPrompt
  }
] as const satisfies readonly SlashCommand[]

export const slashCommandPattern = /^\s*(\/[a-z]+(?:-[a-z]+)*)\b/i

export function slashCommandSignature(command: SlashCommand) {
  return command.args.map((arg) => arg.required ? `<${arg.name}>` : `[${arg.name}]`).join(" ")
}

export function findSlashCommand(text: string): SlashCommandMatch | null {
  const match = text.match(slashCommandPattern)
  if (!match) return null

  const token = match[1].toLowerCase()
  const command = slashCommands.find((item) => item.name === token)
  if (!command) return null

  return {
    command,
    token,
    argsText: text.slice(match[0].length).trim()
  }
}

export function slashCommandQuery(text: string) {
  const match = text.match(/^\s*\/([a-z-]*)$/i)
  return match ? match[1].toLowerCase() : null
}

export function filterSlashCommands(query: string) {
  return slashCommands
    .map((command, index) => ({ command, index, key: command.name.slice(1) }))
    .filter((item) => item.key.includes(query))
    .sort((left, right) => commandMatchRank(left.key, query) - commandMatchRank(right.key, query) || left.index - right.index)
    .map((item) => item.command)
}

export function slashCommandPrompt(text: string) {
  const match = findSlashCommand(text)
  if (!match || match.command.kind !== "skill" || !match.command.toPrompt) return text

  return match.command.toPrompt(match.argsText)
}

function commandMatchRank(commandName: string, query: string) {
  if (commandName === query) return 0
  if (commandName.startsWith(query)) return 1
  return 2
}

function quotedArg(value: string) {
  return JSON.stringify(value.trim())
}

function proposeWizardPrompt(args: string) {
  const trimmed = args.trim()
  const initialContext = trimmed.length > 0
    ? `\n\nThe operator included this initial context after the command:\n${trimmed}`
    : ""

  return `Start the guided Job proposal wizard.

Guide the operator through a natural back-and-forth conversation to draft one Job proposal. Ask for one missing detail at a time, in this order:

1. Job title
2. Job description
3. Optional Epic to attach it to; make it clear they can skip this

After you have enough information, call the propose_job tool to emit exactly one Job proposal card. Do not create a Job directly, and do not ask the operator to fill out a form.${initialContext}`
}
