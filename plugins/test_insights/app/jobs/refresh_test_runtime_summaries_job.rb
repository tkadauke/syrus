# Recomputes derived runtime statistics outside the grader's landing slot.
# TestRun, TestCase, and TestIdentity rows are already durable before this is
# enqueued, so this work does not depend on the ephemeral grader workspace.
#
# Identities refreshed within RuntimeSummary::REFRESH_INTERVAL are skipped:
# see RuntimeSummary.identity_ids_due_for_refresh.
class RefreshTestRuntimeSummariesJob < Syrus::Host::PluginJob
  plugin :test_insights

  def perform(test_identity_ids, grader_name)
    ids = TestInsights::RuntimeSummary.identity_ids_due_for_refresh(test_identity_ids, grader_name: grader_name)
    return if ids.empty?

    TestInsights::RuntimeSummary.refresh_many!(ids, grader_names: [ grader_name ])
  end
end
