# Recomputes TestIdentity summary columns (last status, last pass/fail times,
# recent counts and durations) outside the grader that produced the results.
#
# Ingestion used to do this inline, and the three aggregate reads behind it
# took the bulk of a production ingestion: 56 to 286 seconds after the test
# command had already exited, on the critical path of every test grader and
# therefore of every landing round. Nothing on that path reads the summary
# columns -- flakiness adjudication and failure evidence read TestCase rows,
# which are durable before this is enqueued -- so the refresh waits for a
# worker instead of holding the grader.
#
# Search indexing reads the refreshed columns, so it is enqueued from here,
# after the refresh, rather than beside it.
class RefreshTestIdentitiesJob < Syrus::Host::PluginJob
  plugin :test_insights

  def perform(test_identity_ids)
    ids = Array(test_identity_ids).compact.uniq
    return if ids.empty?

    TestInsights::TestIdentity.refresh_many!(ids)
    IndexTestIdentitiesJob.perform_later(ids)
  end
end
