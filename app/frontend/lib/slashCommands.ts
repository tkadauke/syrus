// "skill" here predates the skill-workflow feature's Skills:: system: it's a canned-prompt
// command (toPrompt synthesizes prose sent as a normal chat message).
// "repo_skill" is the per-repository Skills:: registry (built-ins plus
// .syrus/skills/* overrides) computed dynamically per chat — see
// repoSkillCommands. Its raw text is sent unmodified (no toPrompt) so the
// backend (Skills::ChatInvocation) can parse and resolve it.
export type SlashCommandKind = "system" | "skill" | "repo_skill"

export type SlashCommandArg = {
  name: string
  required?: boolean
}

export type SlashCommand = {
  name: `/${string}`
  kind: SlashCommandKind
  args: SlashCommandArg[]
  description: string | ((context: SlashCommandContext) => string)
  toPrompt?: (args: string) => string
  requiresConfirmation?: boolean
}

export type RepoSkillCommandSource = {
  name: string
  description: string
  parameters: { key: string; required: boolean }[]
}

export type SlashCommandContext = {
  chat?: {
    pinned?: boolean
  }
  dynamicCommands?: SlashCommand[]
}

// Builds the per-chat slash-command list for a repository's resolved skill
// set (built-ins shadowed by .syrus/skills/* overrides, already reflected
// server-side by Skills.all_for). Executes immediately with no toPrompt
// transform and no requiresConfirmation — same trust level as any other
// slash command here; the backend enforces the Coding Mode gate and the
// existing handoff confirmation for any resulting diff.
export function repoSkillCommands(skills: RepoSkillCommandSource[]): SlashCommand[] {
  return skills.map((skill) => ({
    name: `/${skill.name}`,
    kind: "repo_skill",
    args: skill.parameters.map((field) => ({ name: field.key, required: field.required })),
    description: skill.description
  }))
}

export type SlashCommandMatch = {
  command: SlashCommand
  token: string
  argsText: string
}

export const slashCommands = [
  { name: "/rename", kind: "system", args: [{ name: "title", required: true }], description: "slash_commands.rename" },
  { name: "/clear", kind: "system", args: [], description: "slash_commands.clear" },
  { name: "/new", kind: "system", args: [], description: "slash_commands.new" },
  { name: "/branch", kind: "system", args: [], description: "slash_commands.branch" },
  { name: "/bookmarks", kind: "system", args: [], description: "slash_commands.bookmarks" },
  { name: "/settings", kind: "system", args: [], description: "slash_commands.settings" },
  { name: "/copy", kind: "system", args: [], description: "slash_commands.copy" },
  { name: "/search", kind: "system", args: [{ name: "query", required: false }], description: "slash_commands.search" },
  { name: "/pin", kind: "system", args: [], description: (context) => (context.chat?.pinned ? "slash_commands.unpin" : "slash_commands.pin") },
  { name: "/report", kind: "system", args: [], description: "slash_commands.report" },
  { name: "/scratch", kind: "system", args: [{ name: "text", required: false }], description: "slash_commands.scratch" },
  { name: "/share", kind: "system", args: [], description: "slash_commands.share" },
  {
    name: "/schedule",
    kind: "system",
    args: [
      { name: "time", required: false },
      { name: "message", required: false }
    ],
    description: "slash_commands.schedule"
  },
  { name: "/goal", kind: "system", args: [{ name: "action/objective", required: false }], description: "slash_commands.goal" },
  {
    name: "/jobs",
    kind: "system",
    args: [{ name: "filter", required: false }],
    description: "slash_commands.jobs"
  },
  {
    name: "/job",
    kind: "system",
    args: [{ name: "id", required: false }],
    description: "slash_commands.job"
  },
  {
    name: "/epic",
    kind: "system",
    args: [{ name: "id", required: false }],
    description: "slash_commands.epic"
  },
  {
    name: "/prs",
    kind: "system",
    args: [],
    description: "slash_commands.prs"
  },
  {
    name: "/issues",
    kind: "system",
    args: [],
    description: "slash_commands.issues"
  },
  {
    name: "/queue",
    kind: "system",
    args: [],
    description: "slash_commands.queue"
  },
  {
    name: "/spend",
    kind: "system",
    args: [],
    description: "slash_commands.spend"
  },
  {
    name: "/proposals",
    kind: "system",
    args: [],
    description: "slash_commands.proposals"
  },
  {
    name: "/bookmark",
    kind: "system",
    args: [{ name: "label", required: true }],
    description: "slash_commands.bookmark"
  },
  { name: "/discard", kind: "system", args: [{ name: "slug", required: true }], description: "slash_commands.discard", requiresConfirmation: true },
  { name: "/cancel", kind: "system", args: [{ name: "id", required: false }], description: "slash_commands.cancel", requiresConfirmation: true },
  { name: "/retry", kind: "system", args: [{ name: "id", required: false }], description: "slash_commands.retry", requiresConfirmation: true },
  { name: "/review", kind: "system", args: [{ name: "id", required: false }], description: "slash_commands.review" },
  { name: "/approve", kind: "system", args: [{ name: "id", required: false }], description: "slash_commands.approve", requiresConfirmation: true },
  { name: "/feedback", kind: "skill", args: [{ name: "id", required: false }], description: "slash_commands.feedback", requiresConfirmation: true },
  {
    name: "/propose",
    kind: "skill",
    args: [],
    description: "slash_commands.propose",
    toPrompt: proposeWizardPrompt
  },
  {
    name: "/diff",
    kind: "skill",
    args: [{ name: "id", required: false }],
    description: "slash_commands.diff",
    toPrompt: (args) => {
      const id = args.trim()
      return id
        ? `Call the get_job_diff MCP tool for job ${id} and display the diff in a readable summary. Highlight notable changes and call out any concerns.`
        : `Ask the operator which job they want to diff, then call get_job_diff and display a readable summary.`
    }
  },
  {
    name: "/remind",
    kind: "skill",
    args: [{ name: "message", required: false }],
    description: "slash_commands.remind",
    toPrompt: (args) =>
      `The operator wants to set a reminder${args.trim() ? `: ${args.trim()}` : "."} Use the schedule_wakeup MCP tool to schedule a wakeup at the time they specify. Use fire_at for specific dates/times or longer reminders, and delay_minutes only for short relative reminders within 24 hours. If no time is specified, ask for one before calling the tool. Confirm the wakeup time back to the operator after scheduling.`
  }
] as const satisfies readonly SlashCommand[]

export const slashCommandPattern = /^\s*(\/[a-z]+(?:-[a-z]+)*)\b/i

export function slashCommandSignature(command: SlashCommand) {
  return command.args.map((arg) => (arg.required ? `<${arg.name}>` : `[${arg.name}]`)).join(" ")
}

export function slashCommandDescription(command: SlashCommand, context: SlashCommandContext = {}, t: (key: string) => string = (key) => key) {
  const key = typeof command.description === "function" ? command.description(context) : command.description
  return command.kind === "repo_skill" ? key : t(key)
}

export function findSlashCommand(text: string, context: SlashCommandContext = {}): SlashCommandMatch | null {
  const match = text.match(slashCommandPattern)
  if (!match) return null

  const token = match[1].toLowerCase()
  const command = commandsForContext(context).find((item) => item.name === token)
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

export function filterSlashCommands(query: string, context: SlashCommandContext = {}) {
  return commandsForContext(context)
    .map((command, index) => ({ command, index, key: command.name.slice(1) }))
    .filter((item) => item.key.includes(query))
    .sort((left, right) => commandMatchRank(left.key, query) - commandMatchRank(right.key, query) || left.index - right.index)
    .map((item) => item.command)
}

export function slashCommandPrompt(text: string, context: SlashCommandContext = {}) {
  const match = findSlashCommand(text, context)
  if (!match || match.command.kind !== "skill" || !match.command.toPrompt) return text

  return match.command.toPrompt(match.argsText)
}

function commandsForContext(context: SlashCommandContext) {
  const dynamic = (context.dynamicCommands ?? []).filter((command) => !slashCommands.some((existing) => existing.name === command.name))

  return dynamic.length > 0 ? [...slashCommands, ...dynamic] : slashCommands
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
  const initialContext = trimmed.length > 0 ? `\n\nThe operator included this initial context after the command:\n${trimmed}` : ""

  return `Start the guided Job proposal wizard.

Guide the operator through a natural back-and-forth conversation to draft one Job proposal. Ask for one missing detail at a time, in this order:

1. Job title
2. Job description
3. Optional Epic to attach it to; make it clear they can skip this

After you have enough information, call the propose_job tool to emit exactly one Job proposal card. Do not create a Job directly, and do not ask the operator to fill out a form.${initialContext}`
}
