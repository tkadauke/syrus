require "rails_helper"

RSpec.describe ChatChannel::InSyrus do
  let(:repository) { Factories.repository(allow_operator_chat: "in_syrus") }
  let(:run) { Factories.job(repository: repository).initial_run }

  it "creates an OperatorQuestion attached to the Run, Workflow, and Job" do
    question = described_class.new.send_message(
      run: run,
      text: "Which migration strategy should I use?",
      context: { "risk" => "data_backfill" }
    )

    expect(question).to have_attributes(
      run: run,
      workflow: run.workflow,
      job: run.job,
      text: "Which migration strategy should I use?",
      context: { "risk" => "data_backfill" }
    )
    expect(question.asked_at).to be_present
  end

  it "supports multiple Q&A pairs on a single parked Run" do
    channel = described_class.new

    first = channel.send_message(run: run, text: "Use path A?", context: { "turn" => 1 })
    first.record_response!(text: "No, use path B.")
    second = channel.send_message(run: run, text: "Should I preserve the old flag?", context: { "turn" => 2 })
    second.record_response!(text: "Yes.")

    expect(run.operator_questions.reload).to eq([ first, second ])
    expect(first.operator_responses.pluck(:text)).to eq([ "No, use path B." ])
    expect(second.operator_responses.pluck(:text)).to eq([ "Yes." ])
  end

  it "keeps the question inside Syrus persistence only" do
    expect(GithubClient).not_to receive(:new)

    expect {
      described_class.new.send_message(run: run, text: "Sensitive question?", context: { "secret" => "local" })
    }.to change(OperatorQuestion, :count).by(1)
  end
end
