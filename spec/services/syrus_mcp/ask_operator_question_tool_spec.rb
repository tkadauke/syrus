require "rails_helper"

RSpec.describe Mcp::Tools::AskOperatorQuestionTool do
  let(:run) { Factories.job.initial_run }

  it "records a normalized multi-question batch with defaults" do
    response = described_class.call(
      questions: [
        { question: "Which path?", options: [ "Fast", "Careful" ] },
        { question: "Any constraints?" }
      ],
      defaults: [ "Careful", "No additional constraints" ],
      server_context: { run: run }
    )

    expect(response).not_to be_error
    expect(run.agent_questions.sole).to have_attributes(
      questions: [
        { "question" => "Which path?", "options" => [ "Fast", "Careful" ], "multiple" => false },
        { "question" => "Any constraints?", "options" => nil, "multiple" => false }
      ],
      defaults: [ "Careful", "No additional constraints" ]
    )
  end

  it "rejects a missing default" do
    response = described_class.call(
      questions: [ { question: "Which path?" } ], defaults: [], server_context: { run: run }
    )

    expect(response).to be_error
    expect(run.agent_questions).to be_empty
  end
end
