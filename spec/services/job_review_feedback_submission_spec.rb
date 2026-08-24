require "rails_helper"

RSpec.describe JobReviewFeedbackSubmission do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  it "creates a new standalone Job depending on the source Job when it is approved but not yet landed" do
    source_job = Factories.job_record(
      user: user, repository: repository, state: "approved", approved_at: Time.current,
      issue_title: "Add checkout button"
    )

    result = nil
    expect {
      result = described_class.call(source_job: source_job, feedback: "The button color is off.", actor: user)
    }.to change(Job, :count).by(1)

    expect(result).to be_success
    job = result.job
    expect(job).to have_attributes(
      kind: "direct",
      epic_id: nil,
      issue_body: "The button color is off.",
      owner_user: user
    )
    expect(job.issue_title).to include("Add checkout button")
    expect(job.dependencies.sole).to have_attributes(depends_on_job: source_job, source: "manual")
  end

  it "creates a new standalone Job depending on the source Job when it is already closed and merged" do
    source_job = Factories.job_record(
      user: user, repository: repository, state: "closed", closure_reason: "pr_merged"
    )

    result = nil
    expect {
      result = described_class.call(source_job: source_job, feedback: "Please tweak the copy.", actor: user)
    }.to change(Job, :count).by(1)

    expect(result).to be_success
    expect(result.job.dependencies.sole.depends_on_job).to eq(source_job)
  end

  it "does not wrap the new Job in the source Job's Epic" do
    epic = Factories.epic(user: user, repository: repository)
    source_job = Factories.job_record(user: user, repository: repository, state: "approved", epic: epic)

    result = described_class.call(source_job: source_job, feedback: "One more pass.", actor: user)

    expect(result).to be_success
    expect(result.job.epic_id).to be_nil
  end

  it "rejects blank feedback" do
    source_job = Factories.job_record(user: user, repository: repository, state: "approved")

    result = described_class.call(source_job: source_job, feedback: "   ", actor: user)

    expect(result).not_to be_success
    expect(result.error).to include("blank")
  end

  it "rejects a source Job that is neither previewable nor closed" do
    source_job = Factories.job_record(user: user, repository: repository, state: "queued")

    expect {
      result = described_class.call(source_job: source_job, feedback: "Too early.", actor: user)
      expect(result).not_to be_success
    }.not_to change(Job, :count)
  end

  it "rejects a source Job closed for an unsuccessful reason" do
    source_job = Factories.job_record(user: user, repository: repository, state: "closed", closure_reason: "invalidated")

    expect {
      result = described_class.call(source_job: source_job, feedback: "Still relevant?", actor: user)
      expect(result).not_to be_success
    }.not_to change(Job, :count)
  end
end
