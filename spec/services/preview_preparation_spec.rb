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

  it "redacts database credentials from preparation logs and failure evidence" do
    messages = []
    runner = double("ProcessRunner")
    allow(ProcessRunner).to receive(:new) do |options|
      options.fetch(:on_output_chunk).call("connection refused: postgresql://preview:secret-value@postgres/app")
      runner
    end
    allow(runner).to receive(:run).and_return(result(exit_status: 1))

    expect {
      described_class.new(workspace_path, project_id: "web", workflow: workflow, log: ->(message, **) { messages << message }).call
    }.to raise_error(described_class::Error) { |error|
      expect(error.details.fetch("output_tail")).to include("postgresql://preview:[REDACTED]@postgres/app")
      expect(error.details.fetch("output_tail")).not_to include("secret-value")
    }
    expect(messages.join).not_to include("secret-value")
  end

  it "runs provider cleanup when database creation or migration fails" do
    postgres_source = PreviewCommandSource::Config.new(
      start_command_for: ->(port:) { "bin/server --port #{port}" },
      setup_commands: [],
      seed_command: "bin/rails db:create db:migrate db:seed",
      health_check_path: "/up",
      log_paths: [],
      env: {},
      unset_env: [],
      env_for: ->(key:) { { "DATABASE_URL" => "postgresql://preview:secret@postgres/syrus_preview_#{key}" } },
      cleanup_command: "bin/rails db:drop"
    )
    allow(PreviewCommandSource).to receive(:new).with(workspace_path, project_id: "web").and_return(double(resolve: postgres_source))
    failed = double(run: result(exit_status: 1))
    cleaned = double(run: result)
    expect(ProcessRunner).to receive(:new).with(hash_including(command: [ "bash", "-c", postgres_source.seed_command ])).and_return(failed)
    expect(ProcessRunner).to receive(:new).with(hash_including(
      command: [ "bash", "-c", postgres_source.cleanup_command ],
      env: hash_including("DATABASE_URL" => "postgresql://preview:secret@postgres/syrus_preview_review-1")
    )).and_return(cleaned)

    expect {
      described_class.new(workspace_path, project_id: "web", workflow: workflow, preview_key: "review-1").call
    }.to raise_error(described_class::Error, /preview seed failed/)
  end
end
