require "rails_helper"

RSpec.describe OperatorQuestionNudgeJob do
  def parked_run(created_at:, allow_operator_chat: "in_syrus")
    repository = Factories.repository(allow_operator_chat: allow_operator_chat)
    job = Factories.job(repository: repository)
    workflow = job.workflows.first
    step = workflow.steps.first
    run = step.runs.first

    workflow.update_columns(state: "running", started_at: created_at)
    step.update_columns(state: "running", started_at: created_at)
    run.update_columns(
      state: "awaiting_operator",
      created_at: created_at,
      started_at: created_at,
      finished_at: nil,
      nudge_sent: false
    )

    run
  end

  it "nudges a parked run in the day-27 window" do
    freeze_time do
      run = parked_run(created_at: (described_class::NUDGE_AT + 10.minutes).ago)

      expect {
        described_class.perform_now
      }.to change(OperatorQuestion, :count).by(1)

      question = OperatorQuestion.last
      expect(question.run).to eq(run)
      expect(question.text).to eq("Job #42 has been awaiting your response for 27 days; will auto-fail in 3 days if no reply.")
      expect(question.context).to include("kind" => "operator_question_nudge", "run_id" => run.id)
      expect(run.reload.nudge_sent).to be(true)
    end
  end

  it "does not double-nudge the same run" do
    freeze_time do
      run = parked_run(created_at: (described_class::NUDGE_AT + 10.minutes).ago)

      described_class.perform_now

      expect {
        described_class.perform_now
      }.not_to change(OperatorQuestion, :count)
      expect(run.reload.nudge_sent).to be(true)
    end
  end

  it "does not nudge before the day-27 window" do
    freeze_time do
      run = parked_run(created_at: (described_class::NUDGE_AT - 1.hour).ago)

      expect {
        described_class.perform_now
      }.not_to change(OperatorQuestion, :count)
      expect(run.reload.nudge_sent).to be(false)
    end
  end

  it "does not nudge after the narrow day-27 window" do
    freeze_time do
      run = parked_run(created_at: (described_class::NUDGE_AT + described_class::WINDOW + 1.minute).ago)

      expect {
        described_class.perform_now
      }.not_to change(OperatorQuestion, :count)
      expect(run.reload.nudge_sent).to be(false)
    end
  end

  it "does not nudge runs that left awaiting_operator before day 27" do
    freeze_time do
      run = parked_run(created_at: (described_class::NUDGE_AT + 10.minutes).ago)
      run.update!(state: "running")

      expect {
        described_class.perform_now
      }.not_to change(OperatorQuestion, :count)
      expect(run.reload.nudge_sent).to be(false)
    end
  end

  it "uses the configured Telegram channel" do
    freeze_time do
      run = parked_run(created_at: (described_class::NUDGE_AT + 10.minutes).ago, allow_operator_chat: "telegram")

      expect(OperatorChat::Channels::Telegram).to receive(:deliver!) do |question|
        expect(question.run).to eq(run)
        expect(question.text).to eq("Job #42 has been awaiting your response for 27 days; will auto-fail in 3 days if no reply.")
      end

      expect {
        described_class.perform_now
      }.to change(OperatorQuestion, :count).by(1)
      expect(run.reload.nudge_sent).to be(true)
    end
  end
end
