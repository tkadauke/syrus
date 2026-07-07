import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { InstallProgress } from "./InstallProgress"

const steps = (imagePullStatus: SyrusInstallStep["status"]): SyrusInstallStep[] => [
  { id: "runtime_check", status: "ok" },
  { id: "runtime_start", status: "skipped" },
  { id: "compose_resolve", status: "ok" },
  { id: "env_check", status: "ok" },
  { id: "env_generate", status: "ok" },
  { id: "image_pull", status: imagePullStatus },
  { id: "stack_up", status: "pending" },
  { id: "health", status: "pending" }
]

describe("InstallProgress pull progress", () => {
  it("renders a determinate bar with the driver's label while the pull reports progress", () => {
    render(
      <InstallProgress
        steps={steps("running")}
        pullProgress={{ percent: 42, label: "42% (312 MB / 745 MB)" }}
        logLines={[]}
        onCancel={() => {}}
      />
    )

    expect(screen.getByTestId("pull-progress")).toBeTruthy()
    const bar = screen.getByRole("progressbar")
    expect(bar.getAttribute("aria-valuenow")).toBe("42")
    expect((bar.firstElementChild as HTMLElement).style.width).toBe("42%")
    expect(screen.getByText("42% (312 MB / 745 MB)")).toBeTruthy()
  })

  it("stays indeterminate (spinner only) when no percent is known", () => {
    render(<InstallProgress steps={steps("running")} pullProgress={null} logLines={[]} onCancel={() => {}} />)

    expect(screen.queryByTestId("pull-progress")).toBeNull()
    expect(screen.queryByRole("progressbar")).toBeNull()
  })

  it("drops the bar once the pull step has finished", () => {
    render(
      <InstallProgress
        steps={steps("ok")}
        pullProgress={{ percent: 100, label: "100% (745 MB / 745 MB)" }}
        logLines={[]}
        onCancel={() => {}}
      />
    )

    expect(screen.queryByTestId("pull-progress")).toBeNull()
  })

  it("wraps long log lines instead of scrolling horizontally", () => {
    const { container } = render(
      <InstallProgress steps={steps("running")} pullProgress={null} logLines={["a".repeat(500)]} onCancel={() => {}} />
    )

    const pre = container.querySelector("pre")
    expect(pre?.className).toContain("whitespace-pre-wrap")
    expect(pre?.className).toContain("break-words")
  })
})
