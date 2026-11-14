export function jobDetailPayloadPaths(jobID: number) {
  const base = `/api/v1/app/jobs/${jobID}`
  return [base, `${base}/tabs/summary`] as const
}

export function mergeJobDetailPayload<Header extends object, Summary extends object>(header: Header, summary: Summary): Header & Summary {
  return { ...header, ...summary }
}
