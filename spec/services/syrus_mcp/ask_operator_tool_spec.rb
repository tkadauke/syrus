require "rails_helper"

RSpec.describe SyrusMcp::AskOperatorTool do
  let(:repository) { Factories.repository(allow_operator_chat: "in_syrus") }
  let(:run) { Factories.job(repository: repository).initial_run }

  def call(text: "Which option should I use?", context: { "option_count" => 2 })
    described_class.call(text: text, context: context, server_context: { run: run })
  end

  it "routes through the configured chat channel and records the question" do
    expect {
      response = call(text: "Use the public or private API?", context: { "file" => "app/services/foo.rb" })
      expect(response).not_to be_error
    }.to change(OperatorQuestion, :count).by(1)

    question = OperatorQuestion.last
    expect(question).to have_attributes(
      run: run,
      workflow: run.workflow,
      job: run.job,
      text: "Use the public or private API?",
      context: { "file" => "app/services/foo.rb" }
    )
  end

  it "writes an audit line without sending the question to an external provider" do
    expect(GithubClient).not_to receive(:new)

    expect { call(text: "This stays local.") }
      .to change { run.job_logs.count }.by(1)
    expect(run.job_logs.last.chunk).to include("[mcp] ask_operator recorded OperatorQuestion")
  end

  it "rejects blank question text" do
    response = call(text: "   ")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("text is required")
    expect(OperatorQuestion.count).to eq(0)
  end

  it "returns an error when operator chat is disabled" do
    repository.update!(allow_operator_chat: "disabled")

    response = call

    expect(response).to be_error
    expect(response.content.first[:text]).to include("operator chat is not enabled")
    expect(OperatorQuestion.count).to eq(0)
  end

  it "exposes the MCP tool as ask_operator" do
    expect(described_class.tool_name).to eq("ask_operator")
    expect(described_class.input_schema_value.to_h[:required]).to eq(%w[text])
  end
end
