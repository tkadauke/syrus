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

  # `close_job_successfully` validates its closure_reason against
  # Job::SUCCESSFUL_CLOSURE_REASONS and this decision supplied none, so the
  # action it advertised could never have executed -- and no successful reason
  # fits "not actionable" anyway.
  it "offers a classifying action rather than a repair" do
    uncertain!

    expect(described_class.call(job: job).decision.action_keys).to eq([ "cancel_job" ])
  end

  # Without the reason, a person has to guess whether to retry the classifier
  # or read the issue -- which is the whole question the decision exists to
  # put in front of them.
  it "carries the reason the classifier gave up" do
    job.update_columns(state: "triaging", triaging_reason: "classifier_uncertain",
                       triaging_uncertainty_reason: "Judgment timed out after 30s")

    decision = described_class.call(job: job.reload).decision

    expect(decision.summary).to include("Judgment timed out after 30s")
  end

  it "does nothing for a Job that is not awaiting triage" do
    expect(described_class.call(job: job)).to be_nil
  end

  it "does nothing for a Job stuck on classification rather than unclear" do
    job.update_columns(state: "triaging", triaging_reason: "classifier_pending")

    expect(described_class.call(job: job.reload)).to be_nil
  end
end
