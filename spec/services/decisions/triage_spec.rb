require "rails_helper"

RSpec.describe Decisions::Triage do
  let(:job) { Factories.job_record }

  def uncertain!
    job.update_columns(state: "triaging", triaging_reason: "classifier_uncertain")
    job.reload
  end

  it "opens a triage decision for a request the classifier could not place" do
    uncertain!

    result = described_class.call(job: job)

    expect(result).to be_created
    expect(result.decision.queue).to eq("triage")
    expect(result.decision.job).to eq(job)
  end

  # A classifier that could not decide is not an incident.
  it "files it at low urgency" do
    uncertain!

    expect(described_class.call(job: job).decision.urgency).to eq("low")
  end

  it "offers a classifying action rather than a repair" do
    uncertain!

    expect(described_class.call(job: job).decision.action_keys).to eq([ "close_job_successfully" ])
  end

  it "does nothing for a Job that is not awaiting triage" do
    expect(described_class.call(job: job)).to be_nil
  end

  it "does nothing for a Job stuck on classification rather than unclear" do
    job.update_columns(state: "triaging", triaging_reason: "classifier_pending")

    expect(described_class.call(job: job.reload)).to be_nil
  end
end
