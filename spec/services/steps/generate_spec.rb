require "rails_helper"
require "tmpdir"

RSpec.describe Steps::Generate do
  let(:job)      { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step)     { workflow.steps.first.tap { |s| s.update!(kind: "generate") } }
  let(:run)      { step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }
  let(:handler)  { described_class.new(run) }

  let(:failure_result) do
    ProcessRunner::Result.new(
      exit_status: 1, timed_out: false, stopped: false,
      silent_timed_out: false, operator_killed: false,
      aliveness_failed: false, duration_s: 0.1, spawned_process_id: nil
    )
  end

  around do |ex|
    Dir.mktmpdir("syrus-generate") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
    allow(handler).to receive(:commit_agent_changes)
    allow(handler).to receive(:changed_files).and_return(%w[proto/sub/thing.proto])
  end

  def write_syrus_yml(contents)
    @ws_path.join(".syrus.yml").write(contents)
  end

  describe "no changed files" do
    it "skips without consulting .syrus.yml" do
      allow(handler).to receive(:changed_files).and_return([])
      write_syrus_yml(<<~YAML)
        generated:
          - command: echo generated
            generates: "lib/thing.rb"
      YAML
      expect(handler).not_to receive(:commit_agent_changes)

      handler.call

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).to include("no changed files this iteration")
    end
  end

  describe "no generated: key configured" do
    it "no-ops cleanly — there is no plugin-provided default" do
      expect(handler).not_to receive(:commit_agent_changes)

      expect { handler.call }.not_to raise_error

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).to include("no applicable generators")
    end
  end

  describe "explicit .syrus.yml generated:" do
    it "runs an entry whose sources glob matches the diff and commits the result" do
      write_syrus_yml(<<~YAML)
        generated:
          - command: echo buf-generated
            sources: "proto/**/*.proto"
            generates: "lib/proto/thing.rb"
      YAML
      expect(handler).to receive(:commit_agent_changes).with("Generate: apply deterministic code generation")

      handler.call

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).to include("$ echo buf-generated")
    end

    it "skips an entry whose sources glob matches nothing in the diff" do
      write_syrus_yml(<<~YAML)
        generated:
          - command: echo graphql-generated
            sources: "graphql/**/*.graphql"
            generates: "lib/graphql_types.rb"
      YAML
      expect(handler).not_to receive(:commit_agent_changes)

      handler.call

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).not_to include("$ echo graphql-generated")
      expect(chunks).to include("skipped \"echo graphql-generated\" (no matching sources changed)")
    end

    it "always runs an entry with no sources configured" do
      write_syrus_yml(<<~YAML)
        generated:
          - command: bin/rails db:schema:dump
            generates: "db/schema.rb"
      YAML
      expect(handler).to receive(:commit_agent_changes)

      handler.call

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).to include("$ bin/rails db:schema:dump")
    end

    it "skips codegen_ignore entries entirely, even with a matching sources glob" do
      write_syrus_yml(<<~YAML)
        generated:
          - command: bin/rails db:schema:dump
            sources: "proto/**/*.proto"
            generates: "db/schema.rb"
            codegen_ignore: true
      YAML
      expect(handler).not_to receive(:commit_agent_changes)

      handler.call

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).not_to include("$ bin/rails db:schema:dump")
      expect(chunks).to include("skipped \"bin/rails db:schema:dump\" (codegen_ignore)")
    end

    it "soft-fails a failing command instead of raising, and still commits successful entries" do
      write_syrus_yml(<<~YAML)
        generated:
          - command: bad-generator
            sources: "proto/**/*.proto"
            generates: "lib/bad.rb"
      YAML
      fake_runner = instance_double(ProcessRunner, run: failure_result)
      allow(ProcessRunner).to receive(:new).and_return(fake_runner)
      expect(handler).to receive(:commit_agent_changes)

      expect { handler.call }.not_to raise_error

      failures = workflow.reload.artifact("generate_failures")
      expect(failures.first).to include("command" => "bad-generator", "exit_status" => 1, "soft" => true)
      expect(step.reload.details["generate_failures"]).to eq(failures)
    end
  end

  describe "generated: false" do
    it "disables codegen entirely" do
      write_syrus_yml("generated: false\n")
      expect(handler).not_to receive(:commit_agent_changes)

      handler.call

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).to include("generated explicitly disabled")
    end

    it "also disables via the YAML off spelling" do
      write_syrus_yml("generated: off\n")

      handler.call

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).to include("generated explicitly disabled")
    end
  end
end
