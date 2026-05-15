require "rails_helper"

RSpec.describe Epic do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def child_job(epic:, number:, closure_reason: nil)
    job = Factories.job_record(user: user, repository: repository, issue_number: number, epic: epic)
    if closure_reason
      job.update!(closure_reason: closure_reason)
      job.close!
    end
    job
  end

  it "assigns an immutable display number separate from the editable title" do
    epic = described_class.create!(user: user, repository: repository, title: "First pass")

    expect(epic.number).to be_present
    expect(epic.display_number).to eq("EPIC-#{epic.number}")

    expect {
      epic.update!(title: "Revised display name")
    }.not_to change(epic, :number)
  end

  it "auto-promotes backlog to ready when dependencies are done and child jobs are confirmed" do
    epic = described_class.create!(user: user, repository: repository, title: "Dependent")

    expect {
      child_job(epic: epic, number: 10)
    }.to change { epic.reload.state }.from("backlog").to("ready")
  end

  it "does not auto-promote to ready while an Epic dependency is unfinished" do
    prerequisite = described_class.create!(user: user, repository: repository, title: "Prerequisite")
    epic = described_class.create!(user: user, repository: repository, title: "Dependent")
    EpicDependency.create!(epic: epic, depends_on_epic: prerequisite, derived: false)

    expect(epic.reload).to be_backlog
    expect(epic.may_auto_ready?).to be false
  end

  it "keeps ready to in_progress manual and unblocks queued child workflows when started" do
    epic = described_class.create!(user: user, repository: repository, title: "Launch", state: "ready")
    job = Factories.job_record(user: user, repository: repository, issue_number: 20, epic: epic)
    workflow = Workflows::Initial.instantiate(job: job)

    expect(job).not_to be_dependencies_satisfied
    expect(workflow.first_step.runs).to be_empty

    expect {
      epic.start!
    }.to change { epic.state }.from("ready").to("in_progress")
      .and change(Run, :count).by(1)

    expect(workflow.first_step.runs.first).to be_queued
  end

  it "auto-completes in-progress Epics when all child Jobs are merged" do
    epic = described_class.create!(user: user, repository: repository, title: "Ship", state: "in_progress")
    first_job = child_job(epic: epic, number: 30)
    last_job = child_job(epic: epic, number: 31)

    freeze_time do
      first_job.update!(closure_reason: "pr_merged")
      first_job.close!

      expect {
        last_job.update!(closure_reason: "external_pr_merged")
        last_job.close!
      }.to change { epic.reload.state }.from("in_progress").to("done")
      expect(epic.done_at).to eq(Time.current)
    end
  end

  it "blocks invalid AASM transitions but allows documented operator overrides" do
    epic = described_class.create!(user: user, repository: repository, title: "Escape hatch")

    expect(epic.may_auto_complete?).to be false
    expect {
      epic.auto_complete!
    }.not_to change { epic.reload.state }

    freeze_time do
      epic.override_state!("done")
      expect(epic.reload.state).to eq("done")
      expect(epic.done_at).to eq(Time.current)
    end
  end
end
