require "rails_helper"

RSpec.describe OperatorQuestion do
  let(:run) { Factories.repository(allow_operator_chat: "in_syrus").then { |repo| Factories.job(repository: repo).initial_run } }

  it "records operator responses in chronological order" do
    question = described_class.create!(
      run: run,
      workflow: run.workflow,
      job: run.job,
      text: "Which API shape should I use?",
      context: { "file" => "app/models/widget.rb" },
      asked_at: 2.minutes.ago
    )

    second = question.record_response!(text: "Use the existing PORO shape.", responded_at: 1.minute.ago)
    first = question.record_response!(text: "Checking.", responded_at: 2.minutes.ago)

    expect(question.operator_responses.reload).to eq([ first, second ])
  end

  it "rejects a question whose Run, Workflow, and Job do not match" do
    other_run = Factories.job(repository: run.job.repository, issue_number: 43).initial_run

    question = described_class.new(
      run: run,
      workflow: other_run.workflow,
      job: run.job,
      text: "Can this cross threads?",
      context: {}
    )

    expect(question).not_to be_valid
    expect(question.errors[:workflow]).to include("must match the Run's Workflow")
    expect(question.errors[:job]).to include("must match the Workflow's Job")
  end

  it "exposes context-backed delivery metadata for chat integrations" do
    question = described_class.create!(
      run: run,
      workflow: run.workflow,
      job: run.job,
      text: "Which API shape should I use?",
      context: {
        "channel" => "telegram",
        "thread_id" => "telegram:123:456"
      }
    )

    expect(question.channel).to eq("telegram")
    expect(question.thread_id).to eq("telegram:123:456")
    expect(question.repository).to eq(run.job.repository)
  end
end
