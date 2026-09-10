// `!` shell-command-mode detection for the chat composer (the chat shell-command cancellation feature), modeled
// on slashCommands.ts's derived-state pattern: a regex-driven flag/query pair
// computed from the current draft text, no literal "mode" field stored
// anywhere. Command mode is active for as long as the first character of the
// draft is `!` — typing `!` as the first character of an empty composer
// enters it, and backspacing away that leading `!` (including to empty)
// reverts to a normal message draft.
const bangCommandPattern = /^!/

export function isBangCommandMode(text: string) {
  return bangCommandPattern.test(text)
}

// The shell command text after the leading `!`, or null outside command mode.
export function bangCommandText(text: string) {
  return isBangCommandMode(text) ? text.slice(1) : null
}
