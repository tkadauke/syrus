require "rails_helper"

RSpec.describe ChatFeedbackSubmission do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  before { clear_enqueued_jobs }

  it "unapproves the job when it is in approved state" do
    job = Factories.job_record(user: user, repository: repository, state: "approved", approved_at: Time.current)

    result = described_class.call(job: job, feedback: "Needs another pass.", allowed_states: %w[implemented approved])

    expect(result).to be_success
    expect(job.reload).to be_implemented
    expect(job.approved_at).to be_nil
  end

  it "leaves an implemented job in implemented state" do
    job = Factories.job_record(user: user, repository: repository, state: "implemented")

    result = described_class.call(job: job, feedback: "One more thing.", allowed_states: %w[implemented approved])

    expect(result).to be_success
    expect(job.reload).to be_implemented
  end

  it "returns an error for a job in a disallowed state" do
    job = Factories.job_record(user: user, repository: repository, state: "queued")

    result = described_class.call(job: job, feedback: "Can't touch this.", allowed_states: %w[implemented approved])

    expect(result).not_to be_success
    expect(result.error).to include("queued jobs are not actionable")
  end
end
