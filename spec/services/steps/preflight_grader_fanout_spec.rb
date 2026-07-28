require "rails_helper"
require "tmpdir"

RSpec.describe Steps::PreflightGraderFanout do
  let(:job)      { Factories.job }
  let(:workflow) { job.workflows.last }

  let(:collect_step) do
    Step.create!(
      workflow: workflow,
      kind: "preflight_grader_collect",
      position: 102,
      iteration: 1
    )
  end

  let(:step) do
    Step.create!(
      workflow: workflow,
      kind: "preflight_grader_fanout",
      position: 101,
      iteration: 1,
      next_step_id: collect_step.id
    )
  end

  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: step.iteration) }
  let(:handler) { described_class.new(run) }

  around do |ex|
    Dir.mktmpdir("syrus-preflight-fanout") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    collect_step
    step

    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path, base_ref: "origin/main")
    allow(handler).to receive(:workspace).and_return(fake_ws)
  end

  def write_grade_config(content)
    File.write(@ws_path.join(".syrus.yml"), content)
  end

  it "materializes preflight_grader steps for each configured grader" do
    write_grade_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
        - name: lint
          run: bin/rubocop
    YAML

    handler.call

    grader_steps = workflow.steps.where(kind: "preflight_grader").order(:position)
    expect(grader_steps.count).to eq(2)
    expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[rspec lint])
  end

  it "materializes preflight_grader (not grader) steps to avoid loop collisions" do
    write_grade_config(<<~YAML)
      grade:
        - name: tests
          run: bin/rspec
    YAML

    handler.call

    expect(workflow.steps.where(kind: "grader").count).to eq(0)
    expect(workflow.steps.where(kind: "preflight_grader").count).to eq(1)
  end

  it "does not filter graders by when_files_changed — runs all graders regardless" do
    write_grade_config(<<~YAML)
      grade:
        - name: website-build
          run: npm run build
          when_files_changed:
            - "website/**"
        - name: rspec
          run: bin/rspec
    YAML

    handler.call

    names = workflow.steps.where(kind: "preflight_grader").order(:position).map { |s| s.details["name"] }
    expect(names).to eq(%w[website-build rspec])
  end

  it "inserts preflight graders between fanout and collect steps" do
    write_grade_config(<<~YAML)
      grade:
        - name: tests
          run: bin/rspec
    YAML

    handler.call

    ordered = workflow.steps.order(:position).pluck(:kind)
    fanout_idx  = ordered.index("preflight_grader_fanout")
    collect_idx = ordered.index("preflight_grader_collect")
    grader_idx  = ordered.index("preflight_grader")
    expect(grader_idx).to be > fanout_idx
    expect(grader_idx).to be < collect_idx
  end

  it "snapshots grader definition onto the step details" do
    write_grade_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
          required: true
          timeout_minutes: 10
    YAML

    handler.call

    details = workflow.steps.find_by!(kind: "preflight_grader").details
    expect(details).to include(
      "name" => "rspec",
      "command" => "bin/rspec",
      "required" => true,
      "timeout_minutes" => 10
    )
  end

  it "records grade_plan_source in workflow artifacts" do
    write_grade_config(<<~YAML)
      grade:
        - name: tests
          run: bin/rspec
    YAML

    handler.call

    expect(workflow.reload.artifact("preflight_grade_plan_source")).to eq(".syrus.yml")
  end

  it "does nothing and logs when no graders are configured" do
    write_grade_config("prepare: []")

    handler.call

    expect(workflow.steps.where(kind: "preflight_grader").count).to eq(0)
    logs = run.reload.job_logs.pluck(:chunk).join
    expect(logs).to include("no graders configured")
  end

  it "does not check the grader conclusion cache" do
    write_grade_config(<<~YAML)
      grade:
        - name: tests
          run: bin/rspec
    YAML

    expect(GraderConclusionCache).not_to receive(:latest_success)

    handler.call
  end
end
