require "rails_helper"

RSpec.describe PreviewPreparation do
  let(:workspace_path) { "/tmp/preview-workspace" }
  let(:workflow) { instance_double(Workflow) }
  let(:source) do
    PreviewCommandSource::Config.new(
      start_command_for: ->(port:) { "bin/server --port #{port}" },
      setup_commands: [ "bundle install", "npm ci" ],
      seed_command: "bin/seed",
      health_check_path: "/up",
      log_paths: [],
      env: { "RAILS_ENV" => "development" },
      unset_env: []
    )
  end

  def result(exit_status: 0, timed_out: false)
    ProcessRunner::Result.new(
      exit_status: exit_status,
      timed_out: timed_out,
      stopped: false,
      silent_timed_out: false,
      operator_killed: false,
      aliveness_failed: false,
      duration_s: 0.1,
      spawned_process_id: nil
    )
  end

  before do
    allow(PreviewCommandSource).to receive(:new).with(workspace_path, project_id: "web").and_return(double(resolve: source))
    allow(workflow).to receive(:artifact).with("prepared_workspace").and_return({
      "commands" => [ "bundle install", "npm ci" ]
    })
  end

  it "does not repeat setup commands already completed by the workflow prepare step" do
    expect(ProcessRunner).to receive(:new).once.with(hash_including(
      command: [ "bash", "-c", "bin/seed" ],
      kind: "preview",
      workflow: workflow
    )).and_return(double(run: result))

    preparation = described_class.new(workspace_path, project_id: "web", workflow: workflow).call

    expect(preparation["commands"]).to eq([ "bin/seed" ])
  end

  it "returns structured failure evidence for a timed-out seed" do
    allow(ProcessRunner).to receive(:new).and_return(double(run: result(exit_status: nil, timed_out: true)))

    expect {
      described_class.new(workspace_path, project_id: "web", workflow: workflow).call
    }.to raise_error(described_class::Error) { |error|
      expect(error.details).to include(
        "reason" => "preview_seed_failed",
        "phase" => "seed",
        "timed_out" => true
      )
    }
  end
end
