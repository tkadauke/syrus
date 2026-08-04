class IndexTestCaseSearchJob < ApplicationJob
  queue_as :indexing

  def perform(test_case_id)
    test_case = TestCase.includes(:repository).find_by(id: test_case_id)
    unless test_case
      TestCaseSearchIndex.delete(test_case_id)
      return
    end

    TestCaseSearchIndex.upsert(test_case)
  end
end
