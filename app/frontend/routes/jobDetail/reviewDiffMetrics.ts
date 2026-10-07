import { useMutation, useQueryClient } from "@tanstack/react-query"
import type { CoverageDiffAnnotationStatus, CoverageDiffAnnotationsPayload } from "../../api/jobs"
import { patchReviewDiffSettings, type ReviewDiffSettings, type ReviewDiffSettingsPayload } from "../../api/reviewDiffSettings"
import type { DiffLineMetricProvider, DiffLineMetricTone } from "../../components/diff/ReviewableDiff"
import type { ReviewDiffSettingsMetricOption } from "./ReviewDiffSettingsModal"

export function useReviewDiffSettingsMutation(reviewSettings: ReviewDiffSettings) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: patchReviewDiffSettings,
    onMutate: async (patch: Partial<ReviewDiffSettings>) => {
      await queryClient.cancelQueries({ queryKey: ["review_diff_settings"] })
      const previous = queryClient.getQueryData<ReviewDiffSettingsPayload>(["review_diff_settings"])
      const currentSettings = previous?.review_diff_settings ?? reviewSettings
      queryClient.setQueryData<ReviewDiffSettingsPayload>(["review_diff_settings"], {
        ...previous,
        review_diff_settings: { ...currentSettings, ...patch }
      })
      return { previous }
    },
    onError: (_error, _patch, context) => {
      if (context?.previous) queryClient.setQueryData(["review_diff_settings"], context.previous)
    },
    onSuccess: (payload) => {
      queryClient.setQueryData(["review_diff_settings"], payload)
    }
  })
}

export function metricCandidateFromProvider(provider: DiffLineMetricProvider): ReviewDiffSettingsMetricOption {
  return { id: provider.id, label: provider.label }
}

export function activeDiffMetricGutterId(configuredId: string, candidates: ReviewDiffSettingsMetricOption[]) {
  if (configuredId === "off") return "off"
  if (candidates.some((candidate) => candidate.id === configuredId)) return configuredId
  return candidates[0]?.id ?? "off"
}

export function coverageDiffLineMetricProviders(
  annotations: CoverageDiffAnnotationsPayload | null | undefined,
  t: (key: string, options?: Record<string, unknown>) => string
): DiffLineMetricProvider[] {
  if (!hasCoverageAnnotations(annotations)) return []

  return [
    {
      id: "coverage.pr",
      label: t("diff_review.metrics.pr_coverage"),
      metricForLine: ({ file, line }) => {
        if (line.kind !== "add" || line.newLine == null) return null

        const status = annotations?.[file.path]?.[String(line.newLine)]
        if (!status) return null

        return {
          id: "coverage.pr",
          label: t("diff_review.metrics.pr_coverage"),
          tone: coverageMetricTone(status),
          title: t(`diff_review.metrics.pr_coverage_${status}`)
        }
      }
    }
  ]
}

function hasCoverageAnnotations(annotations: CoverageDiffAnnotationsPayload | null | undefined) {
  return Object.values(annotations ?? {}).some((lines) => Object.keys(lines).length > 0)
}

function coverageMetricTone(status: CoverageDiffAnnotationStatus): DiffLineMetricTone {
  const tones: Record<CoverageDiffAnnotationStatus, DiffLineMetricTone> = {
    covered: "success",
    not_executable: "neutral",
    uncovered: "danger"
  }
  return tones[status]
}
