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

  describe "suite-wide shard profile" do
    let(:shard_definition) do
      {
        "grader_framework" => "rspec",
        "shard_runtime_profile_destination" => ".syrus/shard_runtime_rspec-ci.log",
        "shard_runtime_profile_key" => "rspec-ci"
      }
    end

    def shard_context(snapshot_id: 77, workspace: @workspace_path)
      step.update!(details: step.details.merge("source_snapshot_id" => snapshot_id))
      GraderInputMaterialization::Context.new(
        repository: repository, workflow: workflow, step: step, run: run,
        grader_name: "rspec-ci-2-of-4", grader_definition: shard_definition,
        workspace_path: workspace, destination_path: nil
      )
    end

    def shard_profile(workspace = @workspace_path)
      workspace.join(".syrus/shard_runtime_rspec-ci.log").read
    end

    it "writes every file's runtime across graders, not only this shard's" do
      summary!(identity: identity!(file_path: "spec/models/a_spec.rb", name: "a"), avg_duration_ms: 2_000, grader_name: TestInsights::RuntimeSummary::ALL_GRADERS)
      summary!(identity: identity!(file_path: "spec/jobs/b_spec.rb", name: "b"), avg_duration_ms: 40_000, grader_name: TestInsights::RuntimeSummary::ALL_GRADERS)

      described_class.materialize_grader_inputs(shard_context)

      expect(shard_profile).to eq("spec/jobs/b_spec.rb:40.00\nspec/models/a_spec.rb:2.00\n")
    end

    it "gives every shard of a round the same profile even after runtimes change" do
      identity = identity!(file_path: "spec/models/a_spec.rb", name: "a")
      summary = summary!(identity: identity, avg_duration_ms: 2_000, grader_name: TestInsights::RuntimeSummary::ALL_GRADERS)
      described_class.materialize_grader_inputs(shard_context)
      first = shard_profile

      # A shard that finished first updated the live summaries.
      summary.update!(avg_duration_ms: 9_000)
      Dir.mktmpdir("second-shard") do |dir|
        described_class.materialize_grader_inputs(shard_context(workspace: Pathname.new(dir)))

        expect(shard_profile(Pathname.new(dir))).to eq(first)
      end
      expect(TestInsights::ShardRuntimeSnapshot.count).to eq(1)
    end

    it "takes a fresh profile for the next round's source snapshot" do
      summary = summary!(identity: identity!(file_path: "spec/models/a_spec.rb", name: "a"), avg_duration_ms: 2_000, grader_name: TestInsights::RuntimeSummary::ALL_GRADERS)
      described_class.materialize_grader_inputs(shard_context(snapshot_id: 77))
      summary.update!(avg_duration_ms: 9_000)

      described_class.materialize_grader_inputs(shard_context(snapshot_id: 78))

      expect(shard_profile).to eq("spec/models/a_spec.rb:9.00\n")
    end

    it "writes nothing without a source snapshot to key the round by" do
      described_class.materialize_grader_inputs(shard_context(snapshot_id: nil))

      expect(@workspace_path.join(".syrus/shard_runtime_rspec-ci.log")).not_to exist
    end
  end
end
