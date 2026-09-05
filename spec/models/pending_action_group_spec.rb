require "rails_helper"

RSpec.describe PendingActionGroup do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def closed_job(**attrs)
    Factories.job_record(**{ repository: repository, state: "closed" }.merge(attrs))
  end

  def open_job(**attrs)
    Factories.job_record(**{ repository: repository, state: "queued" }.merge(attrs))
  end

  def reopen_job_members(*jobs)
    jobs.map { |job| { action: "reopen_job", payload: { "job_id" => job.id } } }
  end

  describe ".create_with_members!" do
    it "creates a group linking every member pending action by group id" do
      job_one = closed_job
      job_two = closed_job

      group = PendingActionGroup.create_with_members!(
        chat_session: chat_session,
        member_attributes: reopen_job_members(job_one, job_two)
      )

      expect(group).to be_persisted
      expect(group).to be_pending
      expect(group.chat_pending_actions.count).to eq(2)
      expect(group.chat_pending_actions.pluck(:pending_action_group_id).uniq).to eq([ group.id ])
      expect(group.chat_pending_actions.map(&:payload).map { |p| p["job_id"] }).to contain_exactly(job_one.id, job_two.id)
    end

    it "raises without creating anything when member_attributes is empty" do
      expect {
        PendingActionGroup.create_with_members!(chat_session: chat_session, member_attributes: [])
      }.to raise_error(ArgumentError)

      expect(PendingActionGroup.count).to eq(0)
    end

    it "rolls back the whole group when a member fails to validate" do
      job = closed_job

      expect {
        PendingActionGroup.create_with_members!(
          chat_session: chat_session,
          member_attributes: [
            { action: "reopen_job", payload: { "job_id" => job.id } },
            { action: "reopen_job", payload: {} } # missing job_id
          ]
        )
      }.to raise_error(ActiveRecord::RecordInvalid)

      expect(PendingActionGroup.count).to eq(0)
      expect(ChatPendingAction.count).to eq(0)
    end
  end

  describe "#confirm_all!" do
    it "applies every member action and reports success for each" do
      job_one = closed_job
      job_two = closed_job
      group = PendingActionGroup.create_with_members!(
        chat_session: chat_session,
        member_attributes: reopen_job_members(job_one, job_two)
      )

      result = group.confirm_all!(user: user)

      expect(result).to be_all_succeeded
      expect(result.successes.size).to eq(2)
      expect(result.failures).to be_empty
      expect(job_one.reload).to be_open
      expect(job_two.reload).to be_open
      expect(group.reload).to be_confirmed
      expect(group.chat_pending_actions.pluck(:state).uniq).to eq([ "confirmed" ])
    end

    it "reports a failing member without blocking the others from applying" do
      succeeding_job = closed_job
      failing_job = open_job
      group = PendingActionGroup.create_with_members!(
        chat_session: chat_session,
        member_attributes: reopen_job_members(succeeding_job, failing_job)
      )

      result = group.confirm_all!(user: user)

      expect(result.any_failed?).to be true
      expect(result.successes.size).to eq(1)
      expect(result.failures.size).to eq(1)
      expect(result.failures.first.pending_action.payload["job_id"]).to eq(failing_job.id)
      expect(result.failures.first.error).to include("isn't closed")

      expect(succeeding_job.reload).to be_open
      expect(failing_job.reload.state).to eq("queued") # unchanged -- reopen never applied

      # The group itself always reaches "confirmed" -- per-item outcomes
      # live on the member results/pending actions, not on the group state.
      expect(group.reload).to be_confirmed

      by_job_id = group.chat_pending_actions.index_by { |pa| pa.payload["job_id"] }
      expect(by_job_id[succeeding_job.id]).to be_confirmed
      expect(by_job_id[failing_job.id]).to be_failed
      expect(by_job_id[failing_job.id].execution_error).to include("isn't closed")
    end

    it "only confirms members still in the pending state" do
      job_one = closed_job
      job_two = closed_job
      group = PendingActionGroup.create_with_members!(
        chat_session: chat_session,
        member_attributes: reopen_job_members(job_one, job_two)
      )
      already_cancelled = group.chat_pending_actions.first
      already_cancelled.cancel!(user: user)

      result = group.confirm_all!(user: user)

      expect(result.member_results.size).to eq(1)
      expect(already_cancelled.reload).to be_cancelled
    end

    it "does not re-confirm an already confirmed group" do
      job = closed_job
      group = PendingActionGroup.create_with_members!(
        chat_session: chat_session,
        member_attributes: reopen_job_members(job)
      )
      group.confirm_all!(user: user)

      expect(group.confirm_all!(user: user)).to be false
    end
  end

  describe "#reject_all!" do
    it "discards every member action without applying any" do
      job_one = closed_job
      job_two = closed_job
      group = PendingActionGroup.create_with_members!(
        chat_session: chat_session,
        member_attributes: reopen_job_members(job_one, job_two)
      )

      expect(group.reject_all!).to be true
      expect(group.reload).to be_rejected
      expect(group.chat_pending_actions.pluck(:state).uniq).to eq([ "rejected" ])
      expect(job_one.reload).to be_closed
      expect(job_two.reload).to be_closed
    end

    it "does not reject an already rejected group" do
      job = closed_job
      group = PendingActionGroup.create_with_members!(
        chat_session: chat_session,
        member_attributes: reopen_job_members(job)
      )
      group.reject_all!

      expect(group.reject_all!).to be false
    end
  end
end
