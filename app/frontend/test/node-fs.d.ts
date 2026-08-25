// Minimal ambient declaration for the one Node builtin a few tests need
// (reading a source file's raw text) without pulling in @types/node for the
// whole project — see vite.config.ts's rootDir comment for why this repo
// avoids that.
declare module "node:fs" {
  export function readFileSync(path: string, encoding: "utf-8"): string
}
