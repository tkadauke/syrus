require "rails_helper"
require "tmpdir"

RSpec.describe Steps::GraderFanout do
  let(:job)      { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:loop_id)  { SecureRandom.uuid }

  let(:collect_step) do
    Step.create!(
      workflow: workflow,
      kind: "grader_collect",
      position: 102,
      iteration: 1,
      loop_id: loop_id
    )
  end

  let(:step) do
    Step.create!(
      workflow: workflow,
      kind: "grader_fanout",
      position: 101,
      iteration: 1,
      loop_id: loop_id,
      next_step_id: collect_step.id
    )
  end

  # The grader-conclusion cache tests refer to the fanout/collect steps by
  # these names.
  let(:fanout)  { step }
  let(:collect) { collect_step }

  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: step.iteration) }
  let(:handler) { described_class.new(run) }

  around do |ex|
    Dir.mktmpdir("syrus-grader-fanout") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    collect_step  # ensure the continuation step exists before the fanout step
    step          # and the fanout step itself

    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path, base_ref: "origin/main")
    allow(handler).to receive(:workspace).and_return(fake_ws)

    # One shared GitRunner double: current_head_sha reads `rev-parse HEAD`
    # (drives the grader-conclusion cache) and changed_files reads
    # `diff --name-only` (drives the when_files_changed skip). Tests override the
    # diff behavior via stub_changed_files; the rev-parse stub persists.
    @git = instance_double(GitRunner)
    allow(GitRunner).to receive(:new).and_return(@git)
    allow(@git).to receive(:run).with("rev-parse", "HEAD", chdir: anything).and_return("abc123\n")
    allow(@git).to receive(:run).with("diff", "--name-only", anything, chdir: anything).and_return("")
  end

  def write_config(contents)
    File.write(@ws_path.join(".syrus.yml"), contents)
  end

  def write_grade_config(command)
    @ws_path.join(".syrus.yml").write(<<~YAML)
      grade:
        steps:
          - name: tests
            run: #{command}
    YAML
  end

  def stub_changed_files(*files)
    allow(@git).to receive(:run).with("diff", "--name-only", anything, chdir: anything).and_return(files.join("\n"))
  end

  def current_fingerprint
    GraderConclusionCache.fingerprint_for_plan(RepoGradePlan.for(@ws_path))
  end

  # --- when_files_changed skip (PR #1791) ---------------------------------

  it "materializes graders without when_files_changed regardless of changed files" do
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
    YAML
    stub_changed_files("app/models/user.rb")

    handler.call

    grader_steps = workflow.steps.where(kind: "grader")
    expect(grader_steps.count).to eq(1)
    expect(grader_steps.first.details["name"]).to eq("rspec")
  end

  it "materializes graders whose when_files_changed patterns match changed files" do
    write_config(<<~YAML)
      grade:
        - name: website-build
          run: npm --prefix website run build
          when_files_changed:
            - "website/**"
        - name: rspec
          run: bin/rspec
    YAML
    stub_changed_files("website/src/index.js", "app/models/user.rb")

    handler.call

    grader_steps = workflow.steps.where(kind: "grader").order(:position)
    expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[website-build rspec])
  end

  it "skips graders whose when_files_changed patterns do not match any changed files" do
    write_config(<<~YAML)
      grade:
        - name: website-build
          run: npm --prefix website run build
          when_files_changed:
            - "website/**"
        - name: rspec
          run: bin/rspec
    YAML
    stub_changed_files("app/models/user.rb")

    handler.call

    grader_steps = workflow.steps.where(kind: "grader").order(:position)
    expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[rspec])
  end

  it "logs a message for each skipped grader" do
    write_config(<<~YAML)
      grade:
        - name: website-build
          run: npm --prefix website run build
          when_files_changed:
            - "website/**"
        - name: rspec
          run: bin/rspec
    YAML
    stub_changed_files("app/models/user.rb")

    handler.call

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("skipped website-build (no matching files changed)")
  end

  it "stores when_files_changed in the materialized Step details" do
    write_config(<<~YAML)
      grade:
        - name: website-build
          run: npm --prefix website run build
          when_files_changed:
            - "website/**"
            - "docs/**"
    YAML
    stub_changed_files("website/src/index.js")

    handler.call

    grader_step = workflow.steps.find_by(kind: "grader")
    expect(grader_step.details["when_files_changed"]).to eq(%w[website/** docs/**])
  end

  it "passes through when all graders have no when_files_changed and changed_files is empty" do
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
    YAML
    stub_changed_files  # no changed files

    handler.call

    expect(workflow.steps.where(kind: "grader").count).to eq(1)
  end

  it "skips conditional graders and logs a warning when the git diff command fails" do
    write_config(<<~YAML)
      grade:
        - name: website-build
          run: npm --prefix website run build
          when_files_changed:
            - "website/**"
        - name: rspec
          run: bin/rspec
    YAML
    allow(@git).to receive(:run).with("diff", "--name-only", anything, chdir: anything)
      .and_raise(GitRunner::GitError.new([], -1, "no commits yet"))

    handler.call

    grader_steps = workflow.steps.where(kind: "grader").order(:position)
    expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[rspec])
    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("could not determine changed files")
  end

  it "skips through without materializing any steps when all graders are skipped" do
    write_config(<<~YAML)
      grade:
        - name: website-build
          run: npm --prefix website run build
          when_files_changed:
            - "website/**"
    YAML
    stub_changed_files("app/models/user.rb")

    handler.call

    expect(workflow.steps.where(kind: "grader").count).to eq(0)
    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("all graders skipped")
  end

  it "persists the HEAD SHA to the workflow artifact" do
    write_grade_config("bin/rspec")

    handler.call

    expect(workflow.reload.artifact(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY)).to eq("abc123")
  end

  # --- grader-conclusion cache -------------------------------------------

  it "skips materializing graders after a successful conclusion for the same commit and plan" do
    write_grade_config("bin/rspec")
    cached = GraderConclusion.create!(
      repository: job.repository,
      job: job,
      workflow: workflow,
      step: fanout,
      run: run,
      commit_sha: "abc123",
      grader_fingerprint: current_fingerprint,
      grader_name: GraderConclusion::AGGREGATE_NAME,
      required: true,
      status: "passed",
      checked_at: 1.hour.ago
    )

    expect { handler.call }.not_to change { workflow.steps.where(kind: "grader").count }
    expect(workflow.reload.artifact(GraderConclusionCache::ARTIFACT_CACHE_HIT_KEY)).to include(
      "commit_sha" => "abc123",
      "grader_fingerprint" => current_fingerprint,
      "conclusion_id" => cached.id
    )
    expect(fanout.reload.next_step).to eq(collect)
  end

  it "does not reuse failed conclusions for the same commit and plan" do
    write_grade_config("bin/rspec")
    GraderConclusion.create!(
      repository: job.repository,
      job: job,
      workflow: workflow,
      step: fanout,
      run: run,
      commit_sha: "abc123",
      grader_fingerprint: current_fingerprint,
      grader_name: GraderConclusion::AGGREGATE_NAME,
      required: true,
      status: "failed",
      checked_at: 1.hour.ago
    )

    expect { handler.call }.to change { workflow.steps.where(kind: "grader").count }.by(1)
    expect(workflow.reload.artifact(GraderConclusionCache::ARTIFACT_CACHE_HIT_KEY)).to be_nil
    expect(fanout.reload.next_step.kind).to eq("grader")
  end

  it "does not reuse successful conclusions when the grade plan changes" do
    write_grade_config("bin/rspec")
    GraderConclusion.create!(
      repository: job.repository,
      job: job,
      workflow: workflow,
      step: fanout,
      run: run,
      commit_sha: "abc123",
      grader_fingerprint: current_fingerprint,
      grader_name: GraderConclusion::AGGREGATE_NAME,
      required: true,
      status: "passed",
      checked_at: 1.hour.ago
    )
    write_grade_config("bin/rspec spec/models")

    expect { handler.call }.to change { workflow.steps.where(kind: "grader").count }.by(1)
    expect(workflow.reload.artifact(GraderConclusionCache::ARTIFACT_CACHE_HIT_KEY)).to be_nil
  end
end
