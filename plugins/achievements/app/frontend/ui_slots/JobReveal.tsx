import { useQuery, useQueryClient } from "@tanstack/react-query"
import { AchievementRevealQueue } from "../components/AchievementReveal"
import { acknowledgeAchievement, achievementsQueryKey, fetchPendingAchievements } from "../api/achievements"

// Job detail contribution: reveals milestones about this Job the first time an
// authorized user opens it. It reads the same pending and acknowledge APIs as
// the collection page. The list is fetched once per visit so that acknowledging
// one reveal cannot pull the next one out from under the user. A failed fetch
// shows nothing; the reveal stays pending and returns on the next visit.
export default function JobReveal({ job_id }: { job_id?: number; job?: { id: number } }) {
  const queryClient = useQueryClient()
  const pending = useQuery({
    queryKey: [...achievementsQueryKey, "pending", "job", job_id],
    queryFn: () => fetchPendingAchievements({ type: "job", id: job_id as number }),
    enabled: job_id != null,
    staleTime: Infinity,
    gcTime: 0,
    refetchOnWindowFocus: false,
    retry: 2
  })

  if (!pending.data || pending.data.achievements.length === 0) return null

  return (
    <AchievementRevealQueue
      acknowledge={async (unlock) => {
        await acknowledgeAchievement(unlock.id)
        void queryClient.invalidateQueries({ queryKey: achievementsQueryKey, refetchType: "inactive" })
      }}
      reveals={pending.data.achievements}
    />
  )
}
