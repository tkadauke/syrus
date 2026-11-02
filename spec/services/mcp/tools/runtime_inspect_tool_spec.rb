require "rails_helper"

RSpec.describe Mcp::Tools::RuntimeInspectTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }
  let(:session) do
    RuntimeSession.create!(repository: repository, chat_session: chat_session, workspace_ref: "a", provider_key: "stub", display_name: "Stub", state: "running", primary: true)
  end

  before do
    enable_coding_mode!
    register_stub_runtime_provider!
  end

  after { Syrus::PluginRegistry.reset! }

  def call(server_context: { chat_session: chat_session }, **arguments)
    described_class.call(server_context: server_context, **arguments)
  end

  def payload(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  it "delegates to the provider's structural inspection capability" do
    session
    expect(payload(call)).to eq(tree: [])
  end

  it "returns an error for an unknown session_id" do
    response = call(session_id: 999_999_999)

    expect(response).to be_error
  end

  it "operates on the current visual-review Run session" do
    job = Factories.job(repository: repository)
    workflow = job.workflows.last
    step = Step.create!(workflow: workflow, kind: "visual_review", position: 90)
    review_run = Run.create!(job: job, step: step, trigger_kind: workflow.trigger_kind)
    RuntimeSession.create!(
      repository: repository, job: job, workflow: workflow, run: review_run,
      workspace_ref: "workspace", provider_key: "stub", display_name: "Review", state: "running", primary: true
    )

    expect(payload(call(server_context: { run_id: review_run.id }))).to eq(tree: [])
  end
end
