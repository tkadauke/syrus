# Steps never close a Job directly: they record the closure on their Workflow
# (Workflow#request_job_closure!) and JobClosure applies it when the Workflow
# finishes. Step-level specs that call a handler directly stand in for that
# finish with this helper.
module PendingJobClosureHelpers
  def apply_pending_job_closures!
    Workflow.find_each { |workflow| JobClosure.apply_pending!(workflow) }
  end
end

RSpec.configure do |config|
  config.include PendingJobClosureHelpers
end
