require "rails_helper"

RSpec.describe SyrusMcp::AskOperatorTool do
  let(:repository) { Factories.repository(allow_operator_chat: "in_syrus") }
  let(:run) { Factories.job(repository: repository).initial_run }

  before { FileUtils.rm_rf(WorkflowWorkspace.path_for(run.workflow)) }
  after { FileUtils.rm_rf(WorkflowWorkspace.path_for(run.workflow)) }

  def call(question: "Which storage backend should this use?", context: "The issue names two incompatible persistence options.")
    described_class.call(
      question: question,
      context: context,
      server_context: { run: run }
    )
  end

  def create_question!(run:, text: "Prior question?")
    OperatorQuestion.create!(
      run: run,
      workflow: run.workflow,
      job: run.job,
      text: text,
      context: {},
      asked_at: Time.current
    )
  end

  def write_syrus_config(contents)
    path = WorkflowWorkspace.path_for(run.workflow)
    FileUtils.mkdir_p(path)
    File.write(path.join(".syrus.yml"), contents)
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

  it "suppresses operator chat when the source issue has the no-chat label" do
    run.job.update!(operator_chat_disabled: true)

    expect {
      response = call

      expect(response).to be_error
      expect(response.content.first[:text]).to include(Job::OPERATOR_CHAT_OPT_OUT_LABEL)
      expect(response.content.first[:text]).to include("needs_clarification")
    }.to change { run.job_logs.count }.by(1)

    expect(OperatorQuestion.count).to eq(0)
    expect(run.job_logs.last.chunk).to include("ask_operator rejected")
  end

  it "enforces the default per-Workflow question cap across Runs" do
    other_run = Run.create!(job: run.job, step: run.step, trigger_kind: "manual")
    3.times { |i| create_question!(run: run, text: "Run one #{i}?") }
    2.times { |i| create_question!(run: other_run, text: "Run two #{i}?") }

    expect {
      response = call

      expect(response).to be_error
      expect(response.content.first[:text]).to include("question cap hit")
      expect(response.content.first[:text]).to include("(5/5)")
      expect(response.content.first[:text]).to include("needs_clarification")
    }.to change { run.job_logs.count }.by(1)

    expect(OperatorQuestion.count).to eq(5)
    expect(run.job_logs.last.chunk).to include("ask_operator rejected")
  end

  it "uses max_operator_questions from .syrus.yml" do
    write_syrus_config("max_operator_questions: 2\n")
    2.times { |i| create_question!(run: run, text: "Prior #{i}?") }

    response = call

    expect(response).to be_error
    expect(response.content.first[:text]).to include("(2/2)")
    expect(OperatorQuestion.count).to eq(2)
  end

  it "rejects blank question or context" do
    expect(call(question: " ")).to be_error
    expect(call(context: " ")).to be_error
  end
end
