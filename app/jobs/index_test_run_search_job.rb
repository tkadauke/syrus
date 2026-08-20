class IndexTestRunSearchJob < ApplicationJob
  queue_as :indexing

  BATCH_SIZE = 500

  def perform(test_run_id)
    test_run = TestRun.find_by(id: test_run_id)
    return unless test_run

    test_run.test_cases.where.not(test_identity_id: nil).distinct.pluck(:test_identity_id).each_slice(BATCH_SIZE) do |identity_ids|
      TestIdentitySearchIndex.upsert_many(TestIdentity.includes(:repository).where(id: identity_ids))
    end
  end
end
