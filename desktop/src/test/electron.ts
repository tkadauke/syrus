import { vi } from "vitest"

export const getLocale = vi.fn<() => string>()

export const app = { getLocale }
