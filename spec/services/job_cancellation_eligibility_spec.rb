require "rails_helper"

RSpec.describe JobCancellationEligibility do
  def job_double(state)
    instance_double(Job, state: state, slug: "JOB-1")
  end

  it "does not allow cancelling closed jobs and explains why" do
    result = described_class.call(job: job_double("closed"))

    expect(result).not_to be_eligible
    expect(result.message).to eq("JOB-1 is already closed. Reopen it first if more work is required.")
  end

  it "allows every other Job state" do
    (Job.aasm.states.map { |s| s.name.to_s } - ["closed"]).each do |state|
      result = described_class.call(job: job_double(state))
      expect(result).to be_eligible, "expected #{state} to be eligible"
      expect(result.message).to be_nil
    end
  end
end
