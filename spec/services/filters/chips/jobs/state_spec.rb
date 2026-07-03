require "rails_helper"

RSpec.describe Filters::Chips::Jobs::State do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def job_in(state)
    job = Factories.job_record(user: user, repository: repository,
                                issue_number: rand(1..100_000), state: state)
    job.update_column(:state, state) # in case the AASM machinery normalizes
    job
  end

  def apply(value, op: :is)
    described_class.new(scope: Job.all, op: op, value: value, user: user).apply
  end

  describe "#apply" do
    it "matches every non-closed Job for the composite 'open'" do
      triaging   = job_in("triaging")
      queued     = job_in("queued")
      implemented = job_in("implemented")
      approved   = job_in("approved")
      landing    = job_in("landing")
      closed     = job_in("closed")

      results = apply("open").to_a

      expect(results).to include(triaging, queued, implemented, approved, landing)
      expect(results).not_to include(closed)
    end

    it "matches closed Jobs (which now includes merged via closure_reason) for the composite 'closed'" do
      open_job = job_in("queued")
      closed   = job_in("closed")
      merged_closed = job_in("closed")
      merged_closed.update!(closure_reason: "pr_merged")

      results = apply("closed").to_a

      expect(results).to contain_exactly(closed, merged_closed)
      expect(results).not_to include(open_job)
    end

    it "matches only the specific AASM state for a literal individual-state value" do
      implemented = job_in("implemented")
      approved    = job_in("approved")
      landing     = job_in("landing")

      results = apply("implemented").to_a

      expect(results).to contain_exactly(implemented)
      expect(results).not_to include(approved, landing)
    end

    it "matches Jobs in the landing_failed state directly" do
      failed = job_in("landing_failed")
      ok     = job_in("approved")

      results = apply("landing_failed").to_a

      expect(results).to contain_exactly(failed)
      expect(results).not_to include(ok)
    end

    it "negates with is_not for an individual state" do
      implemented = job_in("implemented")
      approved    = job_in("approved")

      results = apply("implemented", op: :is_not).to_a

      expect(results).to include(approved)
      expect(results).not_to include(implemented)
    end

    it "matches the union with is_one_of across individual states" do
      implemented = job_in("implemented")
      approved    = job_in("approved")
      landing     = job_in("landing")

      results = described_class.new(scope: Job.all, op: :is_one_of,
                                     value: %w[implemented approved], user: user).apply.to_a

      expect(results).to contain_exactly(implemented, approved)
      expect(results).not_to include(landing)
    end
  end
end
