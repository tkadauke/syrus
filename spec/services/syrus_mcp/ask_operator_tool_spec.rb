require "rails_helper"

RSpec.describe SyrusMcp::AskOperatorTool do
  let(:repository) { Factories.repository(allow_operator_chat: "in_syrus") }
  let(:run) { Factories.job(repository: repository).initial_run }

  def call(question: "Which storage backend should this use?", context: "The issue names two incompatible persistence options.")
    described_class.call(
      question: question,
      context: context,
      server_context: { run: run }
    )
  end

  it "exposes the tool name as ask_operator" do
    expect(described_class.tool_name).to eq("ask_operator")
    expect(described_class.input_schema_value.to_h[:required]).to eq(%w[question context])
  end

  it "routes through the configured chat channel and records the question" do
    expect {
      response = call(question: "Use the public or private API?", context: "The issue names both.")
      expect(response).not_to be_error
    }.to change(OperatorQuestion, :count).by(1)

    question = OperatorQuestion.last
    expect(question).to have_attributes(
      run: run,
      workflow: run.workflow,
      job: run.job,
      text: "Use the public or private API?",
      context: { "context" => "The issue names both." }
    )
  end

  it "writes an audit line without sending the question to an external provider" do
    expect(GithubClient).not_to receive(:new)

    expect { call(question: "This stays local.") }
      .to change { run.job_logs.count }.by(1)
    expect(run.job_logs.last.chunk).to include("[mcp] ask_operator recorded OperatorQuestion")
  end

  it "returns immediately after dispatching" do
    response = call

    expect(response).not_to be_error
    expect(response.content.first[:text]).to include("Question sent")
    expect(response.content.first[:text]).to include("End your turn")
  end

  it "returns a clear error when operator chat is disabled" do
    repository.update!(allow_operator_chat: "disabled")

    response = call

    expect(response).to be_error
    expect(response.content.first[:text]).to include("operator chat is not enabled")
    expect(response.content.first[:text]).to include("needs_clarification")
    expect(OperatorQuestion.count).to eq(0)
  end

  it "rejects blank question or context" do
    expect(call(question: " ")).to be_error
    expect(call(context: " ")).to be_error
  end
end
