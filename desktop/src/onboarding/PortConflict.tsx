import { useState } from "react"
import { FooterRow, OnboardingScreen, ValidationHint } from "./primitives"

type PortConflictProps = {
  port: number
  onContinue: (port: number) => void
  onBack: () => void
}

export function PortConflict({ port, onContinue, onBack }: PortConflictProps) {
  const [draft, setDraft] = useState(String(port === 3000 ? 3939 : port + 1))
  const parsed = Number.parseInt(draft, 10)
  const valid = Number.isFinite(parsed) && parsed > 1023 && parsed < 65536

  return (
    <OnboardingScreen
      title={`Port ${port} is taken`}
      subtitle={`Something else on this machine is already using port ${port} (often a development server). Pick another port for Syrus.`}
    >
      <div className="mt-6 flex items-center justify-center gap-2">
        <label className="text-sm font-normal text-slate-700 dark:text-slate-300" htmlFor="syrus-port">
          Serve Syrus on port
        </label>
        <input
          id="syrus-port"
          type="number"
          min={1024}
          max={65535}
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
          className="w-24"
        />
      </div>
      <div className="flex justify-center">
        {/* Explains WHY Continue is disabled instead of silently gating it. */}
        <ValidationHint state={draft.trim() === "" ? "empty" : valid ? "valid" : "invalid"}>
          {valid ? `Syrus will listen on http://localhost:${parsed}.` : "Pick a port between 1024 and 65535."}
        </ValidationHint>
      </div>

      <FooterRow>
        <button type="button" className="secondary-button" onClick={onBack}>
          Back
        </button>
        <button type="button" className="primary-button" disabled={!valid} onClick={() => onContinue(parsed)}>
          Continue
        </button>
      </FooterRow>
    </OnboardingScreen>
  )
}
