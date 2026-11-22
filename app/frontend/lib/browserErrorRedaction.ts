export function scrubBrowserErrorText(value: string): string {
  return value
    .replace(/(https?:\/\/[^\s?#]+)\?[^\s#]+/gi, "$1?[FILTERED]")
    .replace(/([?&](?:token|key|secret|password|authorization)=)[^\s&#]+/gi, "$1[FILTERED]")
    .replace(/(\/chats\/shared\/)[^/?#\s]+/gi, "$1[FILTERED]")
    .replace(/(\/passwords\/)[^/?#\s]+(\/edit\b)/gi, "$1[FILTERED]$2")
}
