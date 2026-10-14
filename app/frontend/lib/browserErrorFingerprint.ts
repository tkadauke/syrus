function fnv1a64(input: string): string {
  let hash = 0xcbf29ce484222325n
  const prime = 0x100000001b3n
  const mask = 0xffffffffffffffffn

  for (let index = 0; index < input.length; index += 1) {
    hash ^= BigInt(input.charCodeAt(index))
    hash = (hash * prime) & mask
  }

  return hash.toString(16).padStart(16, "0")
}

export function computeBrowserErrorFingerprint(error: Error): string {
  return fnv1a64(`${error.name}\n${error.message}\n${error.stack ?? ""}`)
}
