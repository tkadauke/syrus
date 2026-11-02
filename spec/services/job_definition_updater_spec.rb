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

      described_class.new(editable).update!(title: "Updated title", description: "Updated description")

      expect(editable.reload).to have_attributes(issue_title: "Updated title", issue_body: "Updated description")
    end
  end

  it "rejects every state at or after execution begins without partially changing the definition" do
    (Job::STATES - described_class::EDITABLE_STATES).each do |state|
      immutable = job(state: state)

      expect {
        described_class.new(immutable).update!(title: "Late title", description: "Late description")
      }.to raise_error(described_class::Immutable, /immutable once work starts.*currently #{state}/)

      expect(immutable.reload).to have_attributes(issue_title: "Original title", issue_body: "Original description")
    end
  end

  it "rejects direct definition writes after execution starts" do
    immutable = job(state: "running")

    expect {
      immutable.update!(issue_title: "Bypassed title", issue_body: "Bypassed description")
    }.to raise_error(ActiveRecord::RecordInvalid, /immutable once work starts.*currently running/)

    expect(immutable.reload).to have_attributes(issue_title: "Original title", issue_body: "Original description")
  end

  it "checks mutability after acquiring the row lock so a concurrent start prevents a late edit" do
    editable = job
    allow(editable).to receive(:lock!).and_wrap_original do |original|
      original.call
      editable.state = "running"
    end

    expect {
      described_class.new(editable).update!(title: "Late title", description: "Late description")
    }.to raise_error(described_class::Immutable, /currently running/)

    expect(editable.reload).to have_attributes(
      issue_title: "Original title",
      issue_body: "Original description"
    )
  end
end
