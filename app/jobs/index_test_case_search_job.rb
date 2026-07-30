class IndexTestCaseSearchJob < ApplicationJob
  queue_as :default

  def perform(test_case_id)
    test_case = TestCase.includes(:repository).find_by(id: test_case_id)
    return unless test_case

    TestCaseSearchIndex.upsert(test_case)
  end
end
