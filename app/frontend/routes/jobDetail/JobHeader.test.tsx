import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { ApiError } from "../../api/client"
import * as jobsApi from "../../api/jobs"
import type { JobDetailPayload } from "../../api/jobs"
import { ShortcutsProvider } from "../../contexts/ShortcutsContext"
import { useJobCommand } from "./command"
import { HeaderActions, PlacementConfirmationModal, PlacementOverrideModal, headerActions } from "./JobHeader"

function renderModal() {
  const mutate = vi.fn()
  const onClose = vi.fn()
  render(
    <PlacementConfirmationModal
      command={{ mutate, isPending: false } as never}
      onClose={onClose}
      path="/api/v1/app/jobs/7/accept_triage"
      recommendation={{
        profile: "macos_desktop",
        label: "macOS desktop",
        capabilities: { os: ["macos"], arch: ["arm64"] },
        explanation: "The desktop package must be tested on macOS.",
        provenance: "ingestion_classifier",
        compatible_worker_available: true
      }}
    />
  )
  return { mutate, onClose }
}

describe("PlacementConfirmationModal", () => {
  it("shows the exact recommendation and submits either explicit decision", () => {
    const { mutate } = renderModal()

    expect(screen.getByText("macOS desktop")).toBeInTheDocument()
    expect(screen.getByText("os: macos · arch: arm64")).toBeInTheDocument()
    expect(screen.getByText("The desktop package must be tested on macOS.")).toBeInTheDocument()
    expect(screen.getByText("A compatible worker is currently available.")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Accept using Linux" }))
    expect(mutate).toHaveBeenCalledWith({ method: "post", path: "/api/v1/app/jobs/7/accept_triage", body: { placement_decision: "linux" } }, expect.any(Object))

    fireEvent.click(screen.getByRole("button", { name: "Accept with suggested placement" }))
    expect(mutate).toHaveBeenCalledWith(
      { method: "post", path: "/api/v1/app/jobs/7/accept_triage", body: { placement_decision: "suggested" } },
      expect.any(Object)
    )
  })

  it("leaves the job unchanged when cancelled", () => {
    const { mutate, onClose } = renderModal()

    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))

    expect(onClose).toHaveBeenCalledOnce()
    expect(mutate).not.toHaveBeenCalled()
  })
})

describe("PlacementOverrideModal", () => {
  it("shows distinct profiles, before/after placement, and requires an audit reason", () => {
    const mutate = vi.fn()
    render(
      <PlacementOverrideModal
        command={{ mutate, isPending: false } as never}
        job={
          {
            id: 7,
            entity_revision: 12,
            planned_execution: { capabilities: { os: ["macos"], arch: ["arm64"], toolchain: ["xcode"], runtime: ["ios_simulator"] } },
            planned_execution_override: {
              eligible: true,
              current_profile: "ios_xcode",
              profiles: [
                { name: "linux", label: "Linux", capabilities: { os: ["linux"] } },
                { name: "macos_desktop", label: "macOS desktop", capabilities: { os: ["macos"], arch: ["arm64"] } },
                { name: "ios_xcode", label: "iOS / Xcode", capabilities: { os: ["macos"], toolchain: ["xcode"], runtime: ["ios_simulator"] } }
              ],
              worker_availability: { linux: true, macos_desktop: false, ios_xcode: true },
              latest_audit: null
            }
          } as never
        }
        onClose={vi.fn()}
        path="/api/v1/app/jobs/7/override_planned_execution"
      />
    )

    expect(screen.getByRole("option", { name: "macOS desktop" })).toBeInTheDocument()
    expect(screen.getByRole("option", { name: "iOS / Xcode" })).toBeInTheDocument()
    const submit = screen.getByRole("button", { name: "Confirm placement change" })
    expect(submit).toBeDisabled()
    fireEvent.change(screen.getByLabelText("Execution profile"), { target: { value: "linux" } })
    fireEvent.change(screen.getByLabelText("Audit reason"), { target: { value: "Classifier selected the mobile bundle." } })
    fireEvent.click(submit)
    expect(mutate).toHaveBeenCalledWith(
      {
        method: "post",
        path: "/api/v1/app/jobs/7/override_planned_execution",
        body: { profile: "linux", reason: "Classifier selected the mobile bundle.", entity_revision: 12 }
      },
      expect.any(Object)
    )
  })
})

describe("headerActions Reset Job", () => {
  const t = ((key: string, options?: Record<string, unknown>) => (options ? `${key}:${JSON.stringify(options)}` : key)) as never
  const base = (actions: Record<string, unknown>) =>
    ({ actions, paths: {}, job: { state: "failed", summary_state: "failed" }, pinned: false }) as never

  it("offers a secondary Reset Job action with a discard list when the payload exposes it", () => {
    const action = headerActions(
      base({
        reset_job_action: {
          path: "/api/v1/app/jobs/7/reset",
          destroys: { open_pr_number: 12, branch: "syrus/job-7", checkpoints: 2, active_workflows: [3] }
        }
      }),
      t
    ).find((entry) => entry.key === "reset_job")

    expect(action?.tone).toBe("secondary")
    expect(action?.input).toMatchObject({ method: "post", path: "/api/v1/app/jobs/7/reset" })
    const confirm = (action?.input as { confirm: string }).confirm
    expect(confirm).toContain("confirm_reset_job")
    expect(confirm).toContain('reset_job_pr:{"number":12}')
    expect(confirm).toContain('reset_job_branch:{"branch":"syrus/job-7"}')
    expect(confirm).toContain('reset_job_checkpoints:{"count":2}')
    expect(confirm).toContain('reset_job_workflows:{"count":1}')
  })

  it("hides Reset Job when the payload does not expose it", () => {
    expect(headerActions(base({ reset_job_action: null }), t).some((entry) => entry.key === "reset_job")).toBe(false)
  })
})

describe("HeaderActions Reset Job interaction", () => {
  const post = vi.fn()

  function Harness({ payload, onNotice }: { payload: JobDetailPayload; onNotice: (message: string | null, tone?: string) => void }) {
    const command = useJobCommand(7, ["job", 7] as never, undefined, onNotice as never)
    return (
      <>
        <HeaderActions command={command} onToggleFeedbackPanel={() => {}} payload={payload} />
        {command.dialog}
      </>
    )
  }

  function payloadFor(state: string, withReset: boolean) {
    return {
      job: { id: 7, state, summary_state: state, kind: "issue" },
      pinned: false,
      paths: {},
      actions: {
        can_write: true,
        reset_job_action: withReset
          ? { path: "/api/v1/app/jobs/7/reset", destroys: { open_pr_number: 12, branch: "syrus/job-7", checkpoints: 2, active_workflows: [3] } }
          : null
      }
    } as unknown as JobDetailPayload
  }

  function renderHarness(payload: JobDetailPayload, onNotice = vi.fn()) {
    const client = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter>
          <ShortcutsProvider>
            <Harness onNotice={onNotice} payload={payload} />
          </ShortcutsProvider>
        </MemoryRouter>
      </QueryClientProvider>
    )
    return onNotice
  }

  beforeEach(() => {
    post.mockReset()
    vi.spyOn(jobsApi, "postJobCommand").mockImplementation(post)
  })

  it("shows Reset Job for a failed Job, confirms with the discard list, and issues the request", async () => {
    post.mockResolvedValue({ message: "reset ok" })
    const onNotice = renderHarness(payloadFor("failed", true))

    fireEvent.click(screen.getByRole("button", { name: "More actions" }))
    fireEvent.click(screen.getByRole("menuitem", { name: "Reset Job" }))

    const dialog = await screen.findByRole("dialog")
    expect(dialog).toHaveTextContent("The Job id, Epic membership, dependencies and history are kept.")
    expect(dialog).toHaveTextContent("PR #12")
    expect(dialog).toHaveTextContent("branch syrus/job-7")
    expect(dialog).toHaveTextContent("2 checkpoints")
    expect(dialog).toHaveTextContent("1 active workflow")
    expect(post).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole("button", { name: "Confirm" }))
    await waitFor(() => expect(post).toHaveBeenCalledWith("/api/v1/app/jobs/7/reset", undefined))
    await waitFor(() => expect(onNotice).toHaveBeenCalledWith("reset ok"))
  })

  it("displays the service refusal when the reset is rejected", async () => {
    post.mockRejectedValue(new ApiError("SYR-7 is landing; cancel or finish landing before reset_job.", { status: 422, code: "validation_failed" }))
    const onNotice = renderHarness(payloadFor("failed", true))

    fireEvent.click(screen.getByRole("button", { name: "More actions" }))
    fireEvent.click(screen.getByRole("menuitem", { name: "Reset Job" }))
    await screen.findByText(/PR #12/)
    fireEvent.click(screen.getByRole("button", { name: "Confirm" }))

    await waitFor(() => expect(onNotice).toHaveBeenCalledWith(expect.stringContaining("is landing"), "error"))
  })

  it("does not offer Reset Job when the payload has no reset action", () => {
    renderHarness(payloadFor("implemented", false))
    fireEvent.click(screen.getByRole("button", { name: "More actions" }))
    expect(screen.queryByRole("menuitem", { name: "Reset Job" })).toBeNull()
  })
})
