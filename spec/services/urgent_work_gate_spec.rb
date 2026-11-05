require "rails_helper"

RSpec.describe UrgentWorkGate do
  let(:job) { Factories.job }

  # Factories.job drives the real creation path, which records state
  # transitions stamped now. Backdate them too, or the Job looks like it just
  # moved and the stall window never applies.
  def urgent!(state: "approved", created_at: 2.days.ago, record: job)
    record.update_columns(priority: "urgent", state: state, created_at: created_at)
    backdate_transitions!(record, created_at)
    record.reload
  end

  def backdate_transitions!(record, at)
    StateTransition.where(subject_type: "Job", subject_id: record.id).update_all(created_at: at)
  end

  # The regression: an urgent Job that cannot land and cannot leave its
  # blocking state used to hold the gate forever, starving every non-urgent
  # Job in its repository.
  it "stops counting an urgent job that has sat still past the stall window" do
    urgent!(created_at: 2.days.ago)
    job.workflows.update_all(state: "succeeded")

    expect(described_class.progressing([ job ])).to be_empty
    expect(described_class).to be_stalled(job)
  end

  it "keeps counting an urgent job that still has runtime work in flight" do
    urgent!(created_at: 2.days.ago)
    job.workflows.first.update_columns(state: "running")

    expect(described_class.progressing([ job ])).to contain_exactly(job)
    expect(described_class).not_to be_stalled(job)
  end

  it "keeps counting an urgent job that moved state recently" do
    urgent!(created_at: 2.days.ago)
    job.workflows.update_all(state: "succeeded")
    StateTransition.create!(subject: job, from_state: "running", to_state: "approved")

    expect(described_class.progressing([ job ])).to contain_exactly(job)
  end

  it "keeps counting a freshly created urgent job with no transition yet" do
    urgent!(state: "needs_triage", created_at: 1.minute.ago)
    job.workflows.update_all(state: "succeeded")

    expect(described_class.progressing([ job ])).to contain_exactly(job)
  end

  it "takes the gate back once a stalled urgent job moves again" do
    urgent!(created_at: 2.days.ago)
    job.workflows.update_all(state: "succeeded")
    expect(described_class.progressing([ job ])).to be_empty

    StateTransition.create!(subject: job, from_state: "approved", to_state: "landing")

    expect(described_class.progressing([ job ])).to contain_exactly(job)
  end

  it "judges each urgent job separately" do
    urgent!(created_at: 2.days.ago)
    job.workflows.update_all(state: "succeeded")
    moving = Factories.job
    urgent!(state: "running", record: moving)
    moving.workflows.first.update_columns(state: "running")

    expect(described_class.progressing([ job, moving.reload ])).to contain_exactly(moving)
  end

  it "returns an empty list unchanged without querying" do
    expect(described_class.progressing([])).to eq([])
    expect(described_class.progressing(nil)).to eq([])
  end
end
