require "rails_helper"

# A confirmation that stops without recording an outcome used to leave the
# action in `confirming` forever: the card renders from the anchored message,
# so it kept a spinner, and the dismiss control could not clear it either.
RSpec.describe ChatPendingAction, "stalled confirmations" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def confirming_action(step: "Starting CI repair rerun...")
    job = Factories.job(repository: repository)
    action = chat_session.pending_actions.create!(action: "cancel_job", payload: { "job_id" => job.id })
    action.update!(state: "confirming", execution_status: "running", execution_step: step)
    action
  end

  describe "#fail_confirmation!" do
    it "records the failure even when the record carries unpersisted changes" do
      action = confirming_action

      # In production this state arrives by rollback: a command that writes
      # progress from inside another record's transaction gets those
      # attributes restored, and so unpersisted, when that transaction rolls
      # back. Set them directly here -- the suite runs each example inside a
      # transaction, so a nested rollback would be swallowed rather than
      # performed, and what matters is the state, not how it was reached.
      action.execution_step = "Creating CI repair rerun..."
      expect(action.changed?).to be(true)
      # The hazard itself: this is what the failure path used to do first.
      expect { action.with_lock { nil } }.to raise_error(RuntimeError, /unpersisted changes/)

      expect(action.fail_confirmation!(RuntimeError.new("upstream exploded"))).to be_truthy

      expect(action.reload).to be_failed
      expect(action.execution_status).to eq("failed")
      # The original error survives instead of being replaced by a lock error.
      expect(action.execution_error).to eq("RuntimeError: upstream exploded")
    end

    it "still records a failure for a clean record" do
      action = confirming_action

      action.fail_confirmation!(RuntimeError.new("plain failure"))

      expect(action.reload).to be_failed
      expect(action.execution_error).to eq("RuntimeError: plain failure")
    end
  end

  describe "#stalled_confirmation?" do
    it "is false while the confirmation is still writing progress" do
      expect(confirming_action.stalled_confirmation?).to be(false)
    end

    it "is true once nothing has touched it for the grace period" do
      action = confirming_action
      action.update_columns(updated_at: (described_class::CONFIRMATION_STALL_GRACE + 1.minute).ago)

      expect(action.reload.stalled_confirmation?).to be(true)
    end

    it "is false for an action that is not confirming" do
      action = chat_session.pending_actions.create!(action: "cancel_job", payload: { "job_id" => 1 })
      action.update_columns(updated_at: 1.day.ago)

      expect(action.reload.stalled_confirmation?).to be(false)
    end
  end

  describe "#fail_stalled_confirmation!" do
    it "fails a stalled action and says so in the recorded error" do
      action = confirming_action
      action.update_columns(updated_at: (described_class::CONFIRMATION_STALL_GRACE + 1.minute).ago)

      expect(action.reload.fail_stalled_confirmation!).to be_truthy

      expect(action.reload).to be_failed
      expect(action.execution_error).to include("ConfirmationStalled")
      expect(action.execution_error).to include("Starting CI repair rerun...")
    end

    it "leaves a confirmation that is still running alone" do
      action = confirming_action

      expect(action.fail_stalled_confirmation!).to be(false)
      expect(action.reload).to be_confirming
    end
  end

  describe ReapStalledPendingActionsJob do
    it "fails stalled confirmations and leaves live ones running" do
      stalled = confirming_action
      stalled.update_columns(updated_at: (ChatPendingAction::CONFIRMATION_STALL_GRACE + 1.minute).ago)
      live = confirming_action

      ReapStalledPendingActionsJob.perform_now

      expect(stalled.reload).to be_failed
      expect(live.reload).to be_confirming
    end
  end
end
