# Recomputes derived runtime statistics outside the grader's landing slot.
# TestRun, TestCase, and TestIdentity rows are already durable before this is
# enqueued, so this work does not depend on the ephemeral grader workspace.
class RefreshTestRuntimeSummariesJob < ApplicationJob
  queue_as :low_priority_maintenance

  def perform(test_identity_ids, grader_name)
    ids = Array(test_identity_ids).compact.uniq
    return if ids.empty?

    TestInsights::RuntimeSummary.refresh_many!(ids, grader_names: [ grader_name ])
  end
end
