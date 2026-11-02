require "rails_helper"

RSpec.describe VisualReviewRuntimeSession do
  let(:job) { Factories.job }
  let(:run) { job.runs.last }
  let(:target) do
    App::VisualReviewRuntimeTargets::Target.new(
      name: "CLI dashboard",
      provider: "stub",
      workspace_path: "/tmp/workspace",
      launch: { "command" => "bin/dashboard" },
      build: { "command" => "bin/build" },
      dimensions: { "columns" => 100, "rows" => 32 },
      review_notes: "Open the jobs screen",
      when_files_changed: [ "cli/**" ],
      captures: [ "jobs loaded" ],
      legacy_browser: false
    )
  end
  let(:provider) do
    instance_double(
      stub_runtime_provider_class,
      start_session: { process_id: 123 },
      build_or_reload: { reloaded: true },
      launch: { launched: true },
      stop_session: true
    )
  end

  before do
    register_stub_runtime_provider!
    allow(stub_runtime_provider_class).to receive(:new).and_return(provider)
  end

  after { Syrus::PluginRegistry.reset! }

  it "owns the provider lifecycle from the visual-review Run workspace" do
    lifecycle = described_class.new(run: run, target: target)

    expect(provider).to receive(:start_session).with(
      "/tmp/workspace",
      hash_including(run: run, workflow: run.workflow, runtime_session: an_instance_of(RuntimeSession), columns: 100, rows: 32)
    ).ordered.and_return(process_id: 123)
    expect(provider).to receive(:build_or_reload).with(kind_of(Integer), target.build).ordered
    expect(provider).to receive(:launch).with(kind_of(Integer), target.launch).ordered

    session = lifecycle.start!

    expect(session).to have_attributes(
      run: run,
      workflow: run.workflow,
      job: job,
      provider_key: "stub",
      workspace_ref: "/tmp/workspace",
      state: "running"
    )
    expect(session.metadata).to include("process_id" => 123, "visual_review_target" => include("captures" => [ "jobs loaded" ]))

    lease = RuntimeControlLease.acquire!(runtime_session: session, owner: "agent", mode: "input")
    expect(provider).to receive(:stop_session).with(session.id)
    lifecycle.stop!
    expect(session.reload.state).to eq("stopped")
    expect(lease.reload.state).to eq("released")
  end

  it "marks the session failed when startup fails" do
    allow(provider).to receive(:start_session).and_raise("terminal unavailable")
    lifecycle = described_class.new(run: run, target: target)

    expect { lifecycle.start! }.to raise_error("terminal unavailable")
    expect(lifecycle.runtime_session.reload).to have_attributes(state: "failed", last_error: include("terminal unavailable"))
  end
end
