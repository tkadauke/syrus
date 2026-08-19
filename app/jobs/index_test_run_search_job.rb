class IndexTestRunSearchJob < ApplicationJob
  queue_as :indexing

  BATCH_SIZE = 500

  def perform(test_run_id)
    test_run = TestRun.find_by(id: test_run_id)
    return unless test_run

    test_run.test_cases.includes(:repository).find_in_batches(batch_size: BATCH_SIZE) do |batch|
      TestCaseSearchIndex.upsert_many(batch)
    end
  end
end
