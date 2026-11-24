import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import i18n from "@app/i18n"
import { jsonResponse } from "@app/testSupport"
import type { WorkbenchCatalog, WorkbenchDefinition } from "../api/workbench"
import { AchievementBadge } from "../components/AchievementBadge"
import { LockedCard, UnlockedCard } from "../components/AchievementCards"
import { AchievementReveal, AchievementRevealContent, AchievementRevealQueue } from "../components/AchievementReveal"
import AchievementsWorkbench from "./AchievementsWorkbench"

const mocks = vi.hoisted(() => ({
  createEmptyChat: vi.fn(),
  sendChatMessage: vi.fn(),
  uploadChatAttachment: vi.fn(),
  html2canvas: vi.fn()
}))
vi.mock("@app/api/chats", () => ({
  createEmptyChat: mocks.createEmptyChat,
  sendChatMessage: mocks.sendChatMessage,
  uploadChatAttachment: mocks.uploadChatAttachment
}))
vi.mock("html2canvas-pro", () => ({ default: mocks.html2canvas }))

function definition(overrides: Partial<WorkbenchDefinition>): WorkbenchDefinition {
  return {
    key: "example.first_job_landed",
    version: 1,
    scope: "user",
    trigger: "job.closed",
    evaluator: "Achievements::Evaluators::FirstOccurrence",
    subject_kinds: ["job"],
    visibility: "visible",
    category: "landing",
    rarity: "common",
    presentation: { title_key: "achievements:example.first_job_landed.title", description_key: "achievements:example.first_job_landed.description" },
    implementation_status: "implemented",
    ...overrides
  }
}

const catalog: WorkbenchCatalog = {
  definitions: [
    definition({}),
    definition({
      key: "example.first_epic_landed",
      scope: "instance",
      trigger: "epic.upserted",
      category: "milestone",
      rarity: "rare",
      presentation: { title_key: "achievements:example.first_epic_landed.title" }
    }),
    definition({
      key: "example.secret_milestone",
      scope: "instance",
      visibility: "hidden",
      category: "milestone",
      rarity: "legendary",
      implementation_status: "planned",
      presentation: { title_key: "achievements:example.secret_milestone.title" }
    })
  ],
  problems: [],
  vocabulary: {
    scope: ["instance", "user"],
    category: ["landing", "milestone"],
    rarity: ["common", "rare", "legendary"],
    visibility: ["visible", "hidden"],
    implementation_status: ["implemented", "partial", "planned"],
    trigger: ["epic.upserted", "job.closed"]
  }
}

function renderPage(path = "/admin/achievements_workbench", response: () => Response = () => jsonResponse(catalog)) {
  vi.spyOn(window, "fetch").mockImplementation(async () => response())
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[path]}>
        <AchievementsWorkbench />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

afterEach(async () => {
  vi.restoreAllMocks()
  Reflect.deleteProperty(window, "matchMedia")
  Object.values(mocks).forEach((mock) => mock.mockReset())
  await i18n.changeLanguage("en")
})

describe("AchievementsWorkbench", () => {
  it("enumerates every registered definition, including hidden ones", async () => {
    renderPage()
    const list = await screen.findByRole("navigation", { name: "Achievement definitions" })
    expect(
      within(list)
        .getAllByRole("link")
        .map((link) => link.textContent)
    ).toEqual([
      expect.stringContaining("example.first_job_landed"),
      expect.stringContaining("example.first_epic_landed"),
      expect.stringContaining("example.secret_milestone")
    ])
    expect(screen.getByText("Showing 3 of 3 definitions")).toBeInTheDocument()
    expect(within(list).getByText("Planned")).toBeInTheDocument()
  })

  it.each([
    ["scope=instance", 2],
    ["category=landing", 1],
    ["rarity=legendary", 1],
    ["trigger=epic.upserted", 1],
    ["visibility=hidden", 1],
    ["implementation_status=planned", 1]
  ])("filters by %s", async (query, count) => {
    renderPage(`/admin/achievements_workbench?${query}`)
    const list = await screen.findByRole("navigation", { name: "Achievement definitions" })
    expect(within(list).getAllByRole("link")).toHaveLength(count)
  })

  it("explains an empty filter result", async () => {
    renderPage("/admin/achievements_workbench?scope=user&rarity=legendary")
    expect(await screen.findByText("No definitions match these filters.")).toBeInTheDocument()
  })

  it("renders the selected fixture through the production badge, card, and reveal markup", async () => {
    renderPage()
    const preview = await screen.findByTestId("workbench-preview")
    expect(within(preview).getAllByTestId("achievement-badge").length).toBeGreaterThanOrEqual(4)
    expect(within(preview).getByTestId("achievement-card")).toHaveTextContent("First Job landed")
    expect(within(preview).getByTestId("achievement-reveal")).toBeInTheDocument()
    expect(within(preview).getByRole("heading", { name: "First Job landed", level: 2 })).toBeInTheDocument()
  })

  it("uses the same components production does (no parallel imitation)", () => {
    const { container } = render(<AchievementBadge rarity="rare" size="lg" />)
    expect(container.querySelector('[data-testid="achievement-badge"]')).toHaveAttribute("data-rarity", "rare")
    // The production reveal dialog and the workbench share one content component.
    expect(AchievementReveal).toBeTypeOf("function")
    expect(AchievementRevealContent).toBeTypeOf("function")
    expect(AchievementRevealQueue).toBeTypeOf("function")
    expect(UnlockedCard).toBeTypeOf("function")
    expect(LockedCard).toBeTypeOf("function")
  })

  it.each([
    ["locked", "achievement-locked"],
    ["unlocked", "achievement-card"],
    ["acknowledged", "achievement-card"],
    ["reset", "achievement-card"]
  ])("shows the %s state", async (state, testId) => {
    renderPage(`/admin/achievements_workbench?state=${state}`)
    const preview = await screen.findByTestId("workbench-preview")
    expect(within(preview).getByTestId(testId)).toBeInTheDocument()
    if (state === "acknowledged") expect(within(preview).queryByText("New")).toBeNull()
    if (state === "reset") expect(within(preview).getByText("New")).toBeInTheDocument()
  })

  it("keeps a hidden definition's copy out of its locked fixture", async () => {
    renderPage("/admin/achievements_workbench?definition=example.secret_milestone&state=locked")
    const preview = await screen.findByTestId("workbench-preview")
    expect(within(preview).getByTestId("achievement-hidden")).not.toHaveTextContent("Secret milestone")
    expect(within(preview).getByTestId("achievement-hidden")).toHaveTextContent("Hidden achievement")
  })

  it("applies responsive viewport presets to the preview frame", async () => {
    renderPage("/admin/achievements_workbench?viewport=phone")
    expect((await screen.findByTestId("workbench-preview")).style.width).toBe("390px")
  })

  it("forces reduced or full motion regardless of the system setting", async () => {
    renderPage("/admin/achievements_workbench?motion=reduced")
    expect((await screen.findByTestId("workbench-preview")).querySelector('[data-testid="achievement-reveal"]')).toHaveAttribute("data-reduced-motion", "true")
  })

  it("replays animation phases", async () => {
    renderPage("/admin/achievements_workbench?motion=full")
    const preview = await screen.findByTestId("workbench-preview")
    const phase = () => preview.querySelector("[data-phase]")
    expect(phase()).toHaveAttribute("data-phase", "end")

    fireEvent.click(screen.getByRole("button", { name: "Start phase" }))
    await waitFor(() => expect(phase()).toHaveAttribute("data-phase", "start"))
    fireEvent.click(screen.getByRole("button", { name: "Replay animation" }))
    await waitFor(() => expect(phase()).toHaveAttribute("data-phase", "end"))
  })

  it("plays stacked reveals through the production queue, one at a time", async () => {
    renderPage()
    fireEvent.click(await screen.findByRole("button", { name: "Play 3 stacked reveals" }))
    expect(await screen.findByRole("dialog")).toBeInTheDocument()
    expect(screen.getByText("1 of 3")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Next" }))
    expect(await screen.findByText("2 of 3")).toBeInTheDocument()
  })

  it("explains that sound testing is unavailable while production has no sound", async () => {
    renderPage()
    expect(await screen.findByText("Reveals have no sound yet, so there is nothing to test.")).toBeInTheDocument()
  })

  it("shows an unavailable notice (not an error) when the workbench is gated off", async () => {
    renderPage("/admin/achievements_workbench", () => jsonResponse({ error: { code: "workbench_unavailable", message: "no" } }, 404))
    expect(await screen.findByText("The workbench is available only while the Achievements and Syrus Dev plugins are both enabled.")).toBeInTheDocument()
  })

  it("has no sound or media elements and exposes labelled controls", async () => {
    renderPage()
    const preview = await screen.findByTestId("workbench-preview")
    expect(preview.querySelector("audio, video")).toBeNull()
    expect(screen.getByRole("navigation", { name: "Fixture state" })).toBeInTheDocument()
    expect(screen.getByRole("navigation", { name: "Viewport" })).toBeInTheDocument()
    expect(screen.getByRole("navigation", { name: "Motion" })).toBeInTheDocument()
    expect(screen.getByRole("region", { name: "Details for example.first_job_landed" })).toBeInTheDocument()
    expect(preview).toHaveAccessibleName("Preview at 1280 pixels wide")
  })

  it("localizes the page in German and Latin", async () => {
    for (const [lang, title] of [
      ["de", "Achievements-Werkbank"],
      ["la", "Officina honorum"]
    ] as const) {
      await i18n.changeLanguage(lang)
      const { unmount } = renderPage()
      expect(await screen.findByRole("heading", { name: title })).toBeInTheDocument()
      unmount()
    }
  })

  describe("Discuss with an agent", () => {
    function pngCanvas() {
      return { toDataURL: () => "data:image/png;base64,AAAA" }
    }

    async function openDialog() {
      renderPage("/admin/achievements_workbench?viewport=tablet&motion=reduced&state=reset")
      fireEvent.click(await screen.findByRole("button", { name: "Discuss with an agent" }))
      return screen.findByRole("dialog")
    }

    it("starts a chat with the screenshot and structured context", async () => {
      mocks.html2canvas.mockResolvedValue(pngCanvas())
      mocks.createEmptyChat.mockResolvedValue({ chat: { id: 7 }, redirect_to: "/chats/7" })
      mocks.uploadChatAttachment.mockResolvedValue({ id: 1, name: "a.png", mime_type: "image/png", size: 4, url: "/x" })
      mocks.sendChatMessage.mockResolvedValue({})
      vi.stubGlobal(
        "fetch",
        vi.fn(async () => new Response(new Blob(["x"])))
      )

      const dialog = await openDialog()
      expect(await within(dialog).findByAltText("Screenshot of the example.first_job_landed preview")).toBeInTheDocument()
      fireEvent.change(within(dialog).getByLabelText("What should the agent look at?"), { target: { value: "Tune the glow" } })
      fireEvent.click(within(dialog).getByRole("button", { name: "Start chat" }))

      await waitFor(() => expect(mocks.sendChatMessage).toHaveBeenCalled())
      const [url, text, attachments] = mocks.sendChatMessage.mock.calls[0]
      expect(url).toBe("/api/v1/app/chats/7/message")
      expect(attachments).toHaveLength(1)
      expect(text).toContain("Tune the glow")
      const context = JSON.parse(text.split("```json\n")[1].split("\n```")[0])
      expect(context).toMatchObject({
        definition: { key: "example.first_job_landed" },
        fixture_state: "reset",
        viewport: { id: "tablet", width: 768 },
        motion: "reduced",
        audio: { supported: false, enabled: false },
        screenshot: { attached: true },
        deep_link: expect.stringContaining("viewport=tablet")
      })
      vi.unstubAllGlobals()
    })

    it("falls back to a screenshot-less discussion when capture fails", async () => {
      vi.spyOn(console, "error").mockImplementation(() => undefined)
      mocks.html2canvas.mockRejectedValue(new Error("tainted canvas"))
      mocks.createEmptyChat.mockResolvedValue({ chat: { id: 8 }, redirect_to: "/chats/8" })
      mocks.sendChatMessage.mockResolvedValue({})

      const dialog = await openDialog()
      expect(await within(dialog).findByRole("alert")).toHaveTextContent("The screenshot could not be captured")
      fireEvent.click(within(dialog).getByRole("button", { name: "Start chat" }))

      await waitFor(() => expect(mocks.sendChatMessage).toHaveBeenCalled())
      expect(mocks.uploadChatAttachment).not.toHaveBeenCalled()
      const [, text, attachments] = mocks.sendChatMessage.mock.calls[0]
      expect(attachments).toEqual([])
      expect(text).toContain("Screenshot: not attached")
    })

    it("surfaces a chat failure and stays open", async () => {
      mocks.html2canvas.mockResolvedValue(pngCanvas())
      mocks.createEmptyChat.mockRejectedValue(new Error("down"))
      vi.stubGlobal(
        "fetch",
        vi.fn(async () => new Response(new Blob(["x"])))
      )

      const dialog = await openDialog()
      await within(dialog).findByAltText(/Screenshot of/)
      fireEvent.click(within(dialog).getByRole("button", { name: "Start chat" }))
      expect(await within(dialog).findByRole("alert")).toBeInTheDocument()
      vi.unstubAllGlobals()
    })
  })
})
