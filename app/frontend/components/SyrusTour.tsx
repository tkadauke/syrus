import { Joyride } from "react-joyride"
import type { EventData, Controls, Step } from "react-joyride"
import { useT } from "../hooks/useT"

type SyrusTourProps = {
  steps: Step[]
  run: boolean
  onEvent?: (data: EventData, controls: Controls) => void
}

// green-600 (#16a34a) matches the "New Job" button used across the app
const PRIMARY_COLOR = "#16a34a"

export function SyrusTour({ steps, run, onEvent }: SyrusTourProps) {
  const { t } = useT("tours")

  return (
    <Joyride
      continuous
      onEvent={onEvent}
      options={{
        buttons: ["back", "skip", "primary"],
        primaryColor: PRIMARY_COLOR,
      }}
      locale={{
        back: t("back"),
        close: t("close"),
        last: t("last"),
        next: t("next"),
        open: t("open"),
        skip: t("skip"),
      }}
      run={run}
      steps={steps}
      styles={{
        tooltip: {
          borderRadius: "6px",
          padding: "20px",
        },
        tooltipContainer: {
          textAlign: "left",
        },
        buttonPrimary: {
          backgroundColor: PRIMARY_COLOR,
          borderRadius: "4px",
          color: "#ffffff",
          fontWeight: "500",
        },
        buttonBack: {
          color: "#374151",
          marginRight: "8px",
        },
        buttonSkip: {
          color: "#6b7280",
        },
        beaconInner: {
          backgroundColor: PRIMARY_COLOR,
        },
        beaconOuter: {
          borderColor: PRIMARY_COLOR,
          backgroundColor: `${PRIMARY_COLOR}33`,
        },
      }}
    />
  )
}
