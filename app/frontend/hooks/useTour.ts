import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { STATUS } from "react-joyride"
import type { EventData } from "react-joyride"
import { fetchBootstrap, type BootstrapPayload } from "../api/bootstrap"
import { postJson } from "../api/client"

export function useTour(tourId: string): {
  run: boolean
  handleJoyrideCallback: (data: Pick<EventData, "status">) => void
} {
  const queryClient = useQueryClient()
  // Tour mutations patch this cache from their small response, so the static
  // bootstrap never needs to be downloaded again.
  const { data: bootstrap } = useQuery({ queryKey: ["bootstrap"], queryFn: fetchBootstrap, staleTime: Infinity })

  const seenTours = bootstrap?.current_user?.seen_tours
  const run = Array.isArray(seenTours) && !seenTours.includes(tourId)

  const dismiss = useMutation({
    mutationFn: () => postJson<{ seen_tours: string[] }>("/api/v1/app/tours/dismiss", { tour_id: tourId }),
    onSuccess: (payload) => {
      queryClient.setQueryData<BootstrapPayload>(["bootstrap"], (current) =>
        current?.current_user ? { ...current, current_user: { ...current.current_user, seen_tours: payload.seen_tours } } : current
      )
    }
  })

  function handleJoyrideCallback(data: Pick<EventData, "status">) {
    if (data.status === STATUS.FINISHED || data.status === STATUS.SKIPPED) {
      dismiss.mutate()
    }
  }

  return { run, handleJoyrideCallback }
}
