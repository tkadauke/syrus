require "rails_helper"
require "tmpdir"

RSpec.describe TestInsights::GraderRuntimeProfileProvider do
  let(:job) { Factories.job }
  let(:repository) { job.repository }
  let(:workflow) { job.workflows.last }
  let(:step) { workflow.steps.create!(kind: "grader", position: 10, details: { "name" => "rspec" }) }
  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: step.iteration) }

  around do |example|
    Dir.mktmpdir("test-insights-runtime-profile") do |dir|
      @workspace_path = Pathname.new(dir)
      example.run
    end
  end

  def context(grader_name: "rspec", destination_path: ".syrus/parallel_runtime_rspec.log")
    GraderInputMaterialization::Context.new(
      repository: repository,
      workflow: workflow,
      step: step,
      run: run,
      grader_name: grader_name,
      grader_definition: { "grader_framework" => "rspec" },
      workspace_path: @workspace_path,
      destination_path: destination_path
    )
  end

  def identity!(file_path:, name:)
    TestInsights::TestIdentity.create!(
      repository: repository,
      fingerprint: TestInsights::TestIdentity.fingerprint_for(suite_name: file_path, name: name),
      suite_name: file_path,
      name: name,
      file_path: file_path
    )
  end

  def summary!(identity:, avg_duration_ms:, grader_name: "rspec")
    TestInsights::RuntimeSummary.create!(
      repository: repository,
      test_identity: identity,
      grader_name: grader_name,
      window: TestInsights::RuntimeSummary::RECENT_100_WINDOW,
      sample_count: 5,
      avg_duration_ms: avg_duration_ms,
      p50_duration_ms: avg_duration_ms,
      p95_duration_ms: avg_duration_ms,
      min_duration_ms: avg_duration_ms,
      max_duration_ms: avg_duration_ms,
      last_observed_at: Time.current
    )
  end

  it "writes a parallel_tests runtime log from recent runtime summaries" do
    FileUtils.mkdir_p(@workspace_path.join("spec/models"))
    File.write(@workspace_path.join("spec/models/widget_spec.rb"), "")
    first = identity!(file_path: "spec/models/widget_spec.rb", name: "fast example")
    second = identity!(file_path: "spec/models/widget_spec.rb", name: "slow example")
    summary!(identity: first, avg_duration_ms: 250)
    summary!(identity: second, avg_duration_ms: 1_250)

    described_class.materialize_grader_inputs(context)

    expect(@workspace_path.join(".syrus/parallel_runtime_rspec.log").read)
      .to eq("spec/models/widget_spec.rb:1.50\n")
  end

  it "ignores deleted or absent spec files" do
    FileUtils.mkdir_p(@workspace_path.join("spec/models"))
    File.write(@workspace_path.join("spec/models/present_spec.rb"), "")
    present = identity!(file_path: "spec/models/present_spec.rb", name: "present")
    deleted = identity!(file_path: "spec/models/deleted_spec.rb", name: "deleted")
    summary!(identity: present, avg_duration_ms: 500)
    summary!(identity: deleted, avg_duration_ms: 9_000)

    described_class.materialize_grader_inputs(context)

    expect(@workspace_path.join(".syrus/parallel_runtime_rspec.log").read)
      .to eq("spec/models/present_spec.rb:0.50\n")
  end

  it "does not write a runtime log for another grader name" do
    FileUtils.mkdir_p(@workspace_path.join("spec/models"))
    File.write(@workspace_path.join("spec/models/widget_spec.rb"), "")
    identity = identity!(file_path: "spec/models/widget_spec.rb", name: "example")
    summary!(identity: identity, avg_duration_ms: 500, grader_name: "rspec")

    described_class.materialize_grader_inputs(context(grader_name: "rspec-ci"))

    expect(@workspace_path.join(".syrus/parallel_runtime_rspec.log")).not_to exist
  end
end
