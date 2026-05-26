require "rails_helper"

RSpec.describe OperatorResponse do
  let(:run) { Factories.repository(allow_operator_chat: "in_syrus").then { |repo| Factories.job(repository: repo).initial_run } }
  let(:question) do
    OperatorQuestion.create!(
      run: run,
      workflow: run.workflow,
      job: run.job,
      text: "What should happen next?",
      context: {}
    )
  end

  it "defaults responded_at when a controller creates a reply" do
    response = described_class.create!(operator_question: question, text: "Use option B.")

    expect(response.responded_at).to be_present
    expect(response.operator_question).to eq(question)
  end

  it "requires response text" do
    response = described_class.new(operator_question: question, text: "")

    expect(response).not_to be_valid
    expect(response.errors[:text]).to be_present
  end
end
