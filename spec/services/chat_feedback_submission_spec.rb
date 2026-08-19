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

  it "dismisses the GitHub review and passes the captured review_id to the propagator" do
    job = Factories.job_record(
      user: user, repository: repository,
      state: "approved", approved_at: Time.current,
      approval_evidence: { "github_review_id" => 999 }
    )

    # review_id must be 999 — proving it was read before unapprove! cleared approval_evidence
    expect(Job::ApprovalPropagator).to receive(:dismiss).with(job, 999, user: user)

    described_class.call(job: job, feedback: "Review this again.", allowed_states: %w[implemented approved])
  end

  it "unapproves before dispatching the workflow so may_unapprove? cannot silently no-op" do
    job = Factories.job_record(
      user: user, repository: repository,
      state: "approved", approved_at: Time.current
    )
    allow(Job::ApprovalPropagator).to receive(:dismiss)

    state_at_dispatch = nil
    allow(StepDispatcher).to receive(:start_workflow) { state_at_dispatch = job.reload.state }

    described_class.call(job: job, feedback: "Please fix.", allowed_states: %w[implemented approved])

    expect(state_at_dispatch).to eq("implemented")
  end

  it "does not call dismiss when the job is not approved" do
    job = Factories.job_record(user: user, repository: repository, state: "implemented")

    expect(Job::ApprovalPropagator).not_to receive(:dismiss)

    described_class.call(job: job, feedback: "One more thing.", allowed_states: %w[implemented approved])
  end

  describe "media" do
    let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

    def whiteboard_snapshot
      WhiteboardSnapshot.create!(
        chat_session: chat_session,
        name: "My snapshot",
        scene_json: { "elements" => [ { "id" => "abc" } ], "appState" => {} },
        snapshot_kind: "manual",
        element_count: 1
      )
    end

    it "attaches referenced media to the job before dispatching the workflow" do
      job = Factories.job_record(user: user, repository: repository, state: "implemented")
      snapshot = whiteboard_snapshot

      result = described_class.call(
        job: job, feedback: "See the attached whiteboard.", allowed_states: %w[implemented approved],
        chat_session: chat_session, media: [ "snapshot:#{snapshot.id}" ]
      )

      expect(result).to be_success
      expect(job.job_attachments.count).to eq(1)
      expect(job.job_attachments.first).to have_attributes(kind: "pending_snapshot", source_url: "snapshot:#{snapshot.id}")
    end

    it "does nothing when media is blank" do
      job = Factories.job_record(user: user, repository: repository, state: "implemented")

      expect(ChatMediaAttacher).not_to receive(:new)

      described_class.call(job: job, feedback: "One more thing.", allowed_states: %w[implemented approved], chat_session: chat_session, media: [])
    end

    it "does nothing when chat_session is not provided" do
      job = Factories.job_record(user: user, repository: repository, state: "implemented")

      expect(ChatMediaAttacher).not_to receive(:new)

      described_class.call(job: job, feedback: "One more thing.", allowed_states: %w[implemented approved], media: [ "snapshot:1" ])
    end
  end
end
