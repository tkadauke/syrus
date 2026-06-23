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
  requiresConfirmation?: boolean
}

export type SlashCommandMatch = {
  command: SlashCommand
  token: string
  argsText: string
}

export const slashCommands = [
  { name: "/rename", kind: "system", args: [{ name: "title", required: true }], description: "Rename the current chat." },
  { name: "/clear", kind: "system", args: [], description: "Clear the current compose draft." },
  { name: "/new", kind: "system", args: [], description: "Start a new chat." },
  { name: "/bookmarks", kind: "system", args: [], description: "Show saved bookmarks in this chat." },
  { name: "/attach", kind: "system", args: [{ name: "target", required: false }], description: "Open attachment controls." },
  { name: "/settings", kind: "system", args: [], description: "Open chat settings." },
  { name: "/jobs", kind: "skill", args: [{ name: "query", required: false }], description: "Ask the agent to inspect Jobs." },
  { name: "/job", kind: "skill", args: [{ name: "id", required: true }], description: "Ask the agent about one Job." },
  { name: "/epic", kind: "skill", args: [{ name: "id", required: false }], description: "Ask the agent about an Epic." },
  { name: "/prs", kind: "skill", args: [{ name: "query", required: false }], description: "Ask the agent to review pull requests." },
  { name: "/issues", kind: "skill", args: [{ name: "query", required: false }], description: "Ask the agent to inspect GitHub issues." },
  { name: "/proposals", kind: "skill", args: [], description: "Ask the agent to summarize proposed work." },
  { name: "/canvas", kind: "skill", args: [{ name: "request", required: false }], description: "Ask the agent to use the whiteboard." },
  { name: "/bookmark", kind: "skill", args: [{ name: "label", required: false }], description: "Ask the agent to bookmark context." },
  { name: "/discard", kind: "skill", args: [{ name: "slug", required: true }], description: "Ask the agent to discard proposed work.", requiresConfirmation: true },
  { name: "/cancel", kind: "skill", args: [{ name: "id", required: true }], description: "Ask the agent to cancel work.", requiresConfirmation: true },
  { name: "/retry", kind: "skill", args: [{ name: "id", required: true }], description: "Ask the agent to retry failed work.", requiresConfirmation: true },
  { name: "/feedback", kind: "skill", args: [{ name: "id", required: true }], description: "Send feedback for the agent to address.", requiresConfirmation: true },
  { name: "/clear-canvas", kind: "skill", args: [], description: "Ask the agent to clear the whiteboard.", requiresConfirmation: true },
  { name: "/propose", kind: "skill", args: [{ name: "request", required: true }], description: "Ask the agent to draft a proposal." }
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

function commandMatchRank(commandName: string, query: string) {
  if (commandName === query) return 0
  if (commandName.startsWith(query)) return 1
  return 2
}
