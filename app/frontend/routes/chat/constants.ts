// Chat UI constants shared across Chat.tsx and its extracted helper/component
// modules. Pure primitive values (thresholds, storage keys, size limits) —
// lifting them here lets helper modules reference them without importing back
// from the 6k-line Chat.tsx (which would create a circular dependency).

export const WHITEBOARD_SAVE_DEBOUNCE_MS = 500

export const CHAT_ENTER_SUBMIT_MIN_WIDTH = 1024

export const CHAT_BOTTOM_THRESHOLD_PX = 48

export const CHAT_TOP_LOAD_THRESHOLD_PX = 96

export const CHAT_INITIAL_FILL_MARGIN_PX = 80

export const CHAT_COMPOSE_MAX_ROWS = 5

export const CHAT_WORKSPACE_WIDTH_KEY = "syrus.chat.workspace.width"

export const CHAT_WORKSPACE_TAB_KEY = "syrus.chat.workspace.tab"

export const CHAT_WORKSPACE_COLLAPSED_KEY = "syrus.chat.workspace.collapsed"

export const CHAT_DRAFT_KEY_PREFIX = "syrus.chat.draft."

// Tab only accepts the ghost suggestion after this grace period. A
// suggestion that streams in asynchronously mid-keystroke must not
// hijack a keyboard user's Tab navigation out of the composer.
export const GHOST_SUGGESTION_TAB_GRACE_MS = 250

export const CHAT_WORKSPACE_DEFAULT_WIDTH = 520

export const CHAT_WORKSPACE_MIN_WIDTH = 360

export const CHAT_WORKSPACE_MAX_WIDTH = 760

// Deliberately wider than AppChromeV2's own 1024px sidebar breakpoint. At
// 1024px, the app's left sidebar (up to 420px) plus the workspace panel
// (min 360px) leave too little room for the chat column, which wraps to
// roughly one word per line. Decoupled so the app sidebar can stay visible
// at widths where the chat-specific split still needs to collapse.
export const CHAT_WORKSPACE_SPLIT_MIN_WIDTH = 1280

export const CHAT_ATTACHMENT_MAX_BYTES = 5 * 1024 * 1024

export const CHAT_ATTACHMENT_TOTAL_MAX_BYTES = 20 * 1024 * 1024

export const WHITEBOARD_MAX_ELEMENTS = 1000

export type ChatQueryKey = readonly ["chats", string, string]
