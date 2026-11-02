require "rails_helper"

RSpec.describe Mcp::Tools::RuntimeCaptureArtifactTool do
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

  it "delegates to the provider's snapshot capability with the artifact_type hint" do
    session
    body = payload(call(artifact_type: "screenshot", checkpoint_label: "menu open"))

    expect(body).to eq(snapshot: true, options: { artifact_type: "screenshot", checkpoint_label: "menu open" })
  end

  it "returns an error when there is no active session" do
    response = call

    expect(response).to be_error
  end

  it "persists workflow provider images as visual-review artifacts" do
    job = Factories.job(repository: repository)
    workflow = job.workflows.last
    step = Step.create!(workflow: workflow, kind: "visual_review", position: 90)
    review_run = Run.create!(job: job, step: step, trigger_kind: workflow.trigger_kind)
    RuntimeSession.create!(
      repository: repository, job: job, workflow: workflow, run: review_run,
      workspace_ref: "workspace", provider_key: "stub", display_name: "Review", state: "running", primary: true
    )
    allow_any_instance_of(stub_runtime_provider_class).to receive(:snapshot).and_return(
      content: [ { type: "image", data: Base64.strict_encode64("png-bytes"), mimeType: "image/png" } ]
    )

    response = call(
      server_context: { run_id: review_run.id },
      artifact_type: "visual_review_cli_menu",
      checkpoint_label: "menu open"
    )

    expect(response).not_to be_error
    artifact = workflow.reload.artifact("typed_artifacts").sole
    expect(artifact).to include(
      "title" => "menu open",
      "original_type" => "visual_review_cli_menu",
      "renderer_type" => "image_diff",
      "run_id" => review_run.id
    )
  end
end
