import { describe, expect, it } from "vitest"
import { createQueryClient } from "./queryClient"

describe("createQueryClient", () => {
  it("uses network-friendly defaults for queries", () => {
    expect(createQueryClient().getDefaultOptions().queries).toMatchObject({
      staleTime: 30_000,
      refetchOnWindowFocus: false,
      retry: 1
    })
  })
})
