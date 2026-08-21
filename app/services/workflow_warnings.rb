# Generic recording helper for deterministic, structural findings surfaced
# on the Job details page with a one-click "file a fix Job" action. Callable
# from any Step handler with a new `kind` string — storage, generic
# rendering, and insight-job discoverability come for free, with zero new
# frontend code required per new kind. Grader side-effect detection
# (Steps::Grader) is the first consumer; see config/syrus_docs/workflow_warnings.md.
module WorkflowWarnings
  def self.record!(workflow:, kind:, title:, step: nil, severity: "medium", evidence: nil, suggested_prompt: nil)
    WorkflowWarning.create!(
      workflow: workflow,
      job: workflow.job,
      step: step,
      kind: kind,
      severity: severity,
      title: title,
      evidence: evidence,
      suggested_prompt: suggested_prompt,
      state: "pending"
    )
  end
end
