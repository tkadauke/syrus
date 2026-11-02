require "rails_helper"

RSpec.describe JobDefinitionUpdater do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def job(state: "queued")
    Factories.job_record(
      user: user,
      repository: repository,
      state: state,
      issue_title: "Original title",
      issue_body: "Original description"
    )
  end

  it "updates title and description together in every pre-execution state" do
    described_class::EDITABLE_STATES.each do |state|
      editable = job(state: state)

      previous_revision = editable.entity_revision
      previous_updated_at = editable.updated_at
      described_class.new(editable).update!(title: "Updated title", description: "Updated description")

      expect(editable.reload).to have_attributes(
        issue_title: "Updated title",
        issue_body: "Updated description",
        entity_revision: previous_revision + 1
      )
      expect(editable.updated_at).to be > previous_updated_at
    end
  end

  it "rejects every state at or after execution begins without partially changing the definition" do
    (Job::STATES - described_class::EDITABLE_STATES).each do |state|
      immutable = job(state: state)

      expect {
        described_class.new(immutable).update!(title: "Late title", description: "Late description")
      }.to raise_error(described_class::Immutable, /immutable once execution starts.*lifecycle state is #{state}/)

      expect(immutable.reload).to have_attributes(issue_title: "Original title", issue_body: "Original description")
    end
  end

  it "rejects direct definition writes after execution starts" do
    immutable = job(state: "running")

    expect {
      immutable.update!(issue_title: "Bypassed title", issue_body: "Bypassed description")
    }.to raise_error(ActiveRecord::RecordInvalid, /immutable once execution starts.*lifecycle state is running/)

    expect(immutable.reload).to have_attributes(issue_title: "Original title", issue_body: "Original description")
  end

  it "rejects stale pre-execution state when a Workflow has started" do
    stale = Factories.job_with_run(user: user, repository: repository, state: "queued",
      workflow_attrs: { state: "running", started_at: 1.minute.ago })

    expect {
      described_class.new(stale).update!(title: "Late title")
    }.to raise_error(described_class::Immutable, /#{stale.workflows.first.slug} has execution evidence/)
  end

  it "rejects stale pre-execution state when a WorkUnit has started" do
    stale = job
    intent = WorkIntent.create!(kind: "initial", state: "requested", scope_type: "job", repository: repository)
    unit = WorkUnit.create!(work_intent: intent, kind: "initial", state: "running", scope_type: "job",
      scope_id: stale.id, repository: repository, started_at: 1.minute.ago)

    expect {
      described_class.new(stale).update!(description: "Late description")
    }.to raise_error(described_class::Immutable, /#{unit.slug} has execution evidence/)
  end

  it "rejects stale pre-execution state when a Run has started" do
    stale = Factories.job_with_run(user: user, repository: repository, state: "queued",
      run_attrs: { state: "running", started_at: 1.minute.ago })

    expect {
      described_class.new(stale).update!(description: "Late description")
    }.to raise_error(described_class::Immutable, /#{stale.runs.first.slug} has execution evidence/)
  end

  it "leaves the complete persisted record unchanged after rejection" do
    immutable = job(state: "running")
    before = immutable.attributes

    expect {
      described_class.new(immutable).update!(title: "Late title", description: "Late description", title_pending: false)
    }.to raise_error(described_class::Immutable)

    expect(immutable.reload.attributes).to eq(before)
  end
end
