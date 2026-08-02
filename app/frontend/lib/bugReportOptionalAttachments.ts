export type BugReportOptionalAttachment = {
  id: string
  label: string
  description?: string
  preview?: string
  defaultChecked?: boolean
  buildFile: () => Promise<File | null> | File | null
}

export type BugReportOpenOptions = {
  optionalAttachments?: BugReportOptionalAttachment[]
}

export function mergeOptionalAttachments(...groups: Array<BugReportOptionalAttachment[] | undefined>) {
  const seen = new Set<string>()
  const merged: BugReportOptionalAttachment[] = []

  groups.flatMap((group) => group ?? []).forEach((attachment) => {
    if (seen.has(attachment.id)) return
    seen.add(attachment.id)
    merged.push(attachment)
  })

  return merged
}
