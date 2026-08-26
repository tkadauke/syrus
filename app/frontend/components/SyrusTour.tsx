import { Joyride } from "react-joyride"
import type { EventData, Controls, Step } from "react-joyride"
import { useT } from "../hooks/useT"
import { useColorTokens } from "../lib/colorTokens"

type SyrusTourProps = {
  steps: Step[]
  run: boolean
  onEvent?: (data: EventData, controls: Controls) => void
}

export function SyrusTour({ steps, run, onEvent }: SyrusTourProps) {
  const { t } = useT("tours")
  const [primaryColor, backColor, skipColor] = useColorTokens(["--color-brand", "--color-neutral", "--color-text-secondary"])

  if (!run) return null

  return (
    <Joyride
      continuous
      onEvent={onEvent}
      options={{
        buttons: ["back", "skip", "primary"],
        primaryColor,
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
          backgroundColor: primaryColor,
          borderRadius: "4px",
          color: "#ffffff",
          fontWeight: "500",
        },
        buttonBack: {
          color: backColor,
          marginRight: "8px",
        },
        buttonSkip: {
          color: skipColor,
        },
        beaconInner: {
          backgroundColor: primaryColor,
        },
        beaconOuter: {
          borderColor: primaryColor,
          backgroundColor: `${primaryColor}33`,
        },
      }}
    />
  )
}
