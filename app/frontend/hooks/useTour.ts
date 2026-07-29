import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { STATUS } from "react-joyride"
import type { EventData } from "react-joyride"
import { fetchBootstrap } from "../api/bootstrap"
import { postJson } from "../api/client"

export function useTour(tourId: string): {
  run: boolean
  handleJoyrideCallback: (data: Pick<EventData, "status">) => void
} {
  const queryClient = useQueryClient()
  const { data: bootstrap } = useQuery({ queryKey: ["bootstrap"], queryFn: fetchBootstrap })

  const seenTours = bootstrap?.current_user?.seen_tours ?? []
  const run = !seenTours.includes(tourId)

  const dismiss = useMutation({
    mutationFn: () => postJson("/api/v1/app/tours/dismiss", { tour_id: tourId }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["bootstrap"] })
    }
  })

  function handleJoyrideCallback(data: Pick<EventData, "status">) {
    if (data.status === STATUS.FINISHED || data.status === STATUS.SKIPPED) {
      dismiss.mutate()
    }
  }

  return { run, handleJoyrideCallback }
}
