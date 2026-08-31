require "rails_helper"
require "tmpdir"

RSpec.describe Steps::GraderFanout, :ci_only do
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

  it "uses review-phase graders on the first implementation validation pass" do
    write_config(<<~YAML)
      grade:
        - name: smoke
          run: bin/smoke
          phases: [review]
        - name: rspec
          run: bin/rspec
          phases: [landing]
    YAML

    handler.call

    details = workflow.steps.find_by!(kind: "grader").details
    expect(details["name"]).to eq("smoke")
    expect(details["command"]).to eq("bin/smoke")
    expect(details["phase"]).to eq("review")
    expect(details["configured_phases"]).to eq([ "review" ])
  end

  it "uses landing-phase graders for landing validations" do
    workflow.update!(trigger_kind: "auto_merge")
    write_config(<<~YAML)
      grade:
        - name: smoke
          run: bin/smoke
          phases: [review]
        - name: rspec
          run: bin/rspec
          phases: [landing]
    YAML

    handler.call

    details = workflow.steps.find_by!(kind: "grader").details
    expect(details["name"]).to eq("rspec")
    expect(details["command"]).to eq("bin/rspec")
    expect(details["phase"]).to eq("landing")
  end

  it "uses landing-phase graders for speculative landing validations" do
    workflow.update!(trigger_kind: "landing_validation")
    write_config(<<~YAML)
      grade:
        - name: smoke
          run: bin/smoke
          phases: [review]
        - name: rspec
          run: bin/rspec
          phases: [landing]
    YAML

    handler.call

    details = workflow.steps.find_by!(kind: "grader").details
    expect(details["name"]).to eq("rspec")
    expect(details["command"]).to eq("bin/rspec")
    expect(details["phase"]).to eq("landing")
  end

  it "computes changed files from the predicted base for speculative landing validations" do
    workflow.update!(trigger_kind: "landing_validation")
    workflow.set_artifact!("predicted_base_sha", "predicted-base")
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
          when_files_changed:
            - app/**/*.rb
    YAML

    expect(@git).to receive(:run)
      .with("diff", "--name-only", "predicted-base...HEAD", chdir: @ws_path.to_s)
      .and_return("app/models/job.rb\n")

    handler.call

    expect(workflow.steps.where(kind: "grader").count).to eq(1)
  end

  it "uses explicit CI-phase graders for CI failure validations" do
    workflow.update!(trigger_kind: "ci_failure")
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
          phases: [landing]
        - name: rspec-ci
          run: RUN_CI_ONLY_SPECS=true bin/rspec
          phases: [ci]
    YAML

    handler.call

    details = workflow.steps.find_by!(kind: "grader").details
    expect(details["name"]).to eq("rspec-ci")
    expect(details["command"]).to eq("RUN_CI_ONLY_SPECS=true bin/rspec")
    expect(details["phase"]).to eq("ci")
  end

  it "expands a legacy ci command into a CI-phase grader" do
    workflow.update!(trigger_kind: "main_grader")
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
          ci: bin/rspec-ci
    YAML

    handler.call

    details = workflow.steps.find_by!(kind: "grader").details
    expect(details["name"]).to eq("rspec-ci")
    expect(details["command"]).to eq("bin/rspec-ci")
    expect(details["phase"]).to eq("ci")
    expect(details["legacy_ci_command"]).to be true
    expect(details["legacy_source_grader"]).to eq("rspec")
  end

  it "uses all-phase graders for main branch graders when no CI-specific grader is configured" do
    workflow.update!(trigger_kind: "main_grader")
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
    YAML

    handler.call

    details = workflow.steps.find_by!(kind: "grader").details
    expect(details["command"]).to eq("bin/rspec")
    expect(details["phase"]).to eq("ci")
  end

  it "uses all-phase graders in CI failure contexts when no CI-specific grader is configured" do
    workflow.update!(trigger_kind: "ci_failure")
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
    YAML

    handler.call

    details = workflow.steps.find_by!(kind: "grader").details
    expect(details["command"]).to eq("bin/rspec")
    expect(details["phase"]).to eq("ci")
  end

  # Repos mid-upgrade may still declare `fast:`. It is parsed so the config
  # keeps loading, but it selects nothing.
  it "ignores a legacy fast command and uses run" do
    workflow.update!(trigger_kind: "auto_merge")
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
          fast: COVERAGE=false bin/rspec
    YAML

    handler.call

    details = workflow.steps.find_by!(kind: "grader").details
    expect(details["command"]).to eq("bin/rspec")
    expect(details).not_to have_key("fast_command")
    expect(details).not_to have_key("fast_variant")
  end

  it "uses the same command on later grade-loop iterations" do
    step.update!(iteration: 2)
    collect.update!(iteration: 2)
    run.update!(iteration: 2)
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
    YAML

    handler.call

    expect(workflow.steps.find_by!(kind: "grader").details["command"]).to eq("bin/rspec")
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

  it "does not materialize a duplicate grader batch when fanout is retried after inserting steps" do
    write_config(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
        - name: react-tests
          run: bin/test-react
    YAML

    handler.call
    first_batch_ids = workflow.steps.where(kind: "grader").order(:position).pluck(:id)

    handler.call

    grader_steps = workflow.steps.where(kind: "grader").order(:position)
    expect(grader_steps.pluck(:id)).to eq(first_batch_ids)
    expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[rspec react-tests])
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

  it "stores junit_output in the materialized Step details when configured" do
    write_config(<<~YAML)
      grade:
        - name: tests
          run: bin/rspec
          junit_output: tmp/rspec-results.xml
    YAML

    handler.call

    grader_step = workflow.steps.find_by(kind: "grader")
    expect(grader_step.details["junit_output"]).to eq("tmp/rspec-results.xml")
  end

  it "stores nil for junit_output in the materialized Step details when not configured" do
    write_grade_config("bin/rspec")

    handler.call

    grader_step = workflow.steps.find_by(kind: "grader")
    expect(grader_step.details["junit_output"]).to be_nil
  end

  it "stores explicit failures policy in the materialized Step details" do
    write_config(<<~YAML)
      grade:
        failures: allow_inherited
        steps:
          - name: tests
            run: bin/rspec
    YAML

    handler.call

    grader_step = workflow.steps.find_by(kind: "grader")
    expect(grader_step.details["failures"]).to eq("allow_inherited")
  end

  it "stores strict failures policy by default" do
    write_config(<<~YAML)
      grade:
        - name: react-tests
          run: bin/test-react
          junit_output: .syrus/grade-output/react-tests-junit.xml
    YAML

    handler.call

    grader_step = workflow.steps.find_by(kind: "grader")
    expect(grader_step.details["failures"]).to eq("strict")
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

  # --- :affected_test_analyzer (EPIC-244) ---------------------------------

  describe ":affected_test_analyzer" do
    after { Syrus::PluginRegistry.reset! }

    def register_analyzer(&block)
      analyzer = Class.new do
        define_singleton_method(:affected_files, &block)
      end
      Syrus::PluginRegistry.register(:affected_test_analyzer, analyzer)
      analyzer
    end

    it "is unaffected when no analyzer is registered (regression-safe default)" do
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

    it "runs a grader an analyzer reports as transitively affected, which glob-only matching would have skipped" do
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
      register_analyzer { |repo_path:, changed_files:| [ "website/src/generated_from_user.js" ] }

      handler.call

      grader_steps = workflow.steps.where(kind: "grader").order(:position)
      expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[website-build rspec])
    end

    it "does not affect graders whose when_files_changed already matches the raw diff" do
      write_config(<<~YAML)
        grade:
          - name: rspec
            run: bin/rspec
            when_files_changed:
              - "app/**"
      YAML
      stub_changed_files("app/models/user.rb")
      register_analyzer { |repo_path:, changed_files:| [] }

      handler.call

      expect(workflow.steps.where(kind: "grader").count).to eq(1)
    end

    it "falls back to glob-only behavior when the analyzer declines by returning nil" do
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
      register_analyzer { |repo_path:, changed_files:| nil }

      handler.call

      grader_steps = workflow.steps.where(kind: "grader").order(:position)
      expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[rspec])
    end

    it "falls back to glob-only behavior rather than silently skipping a grader when the analyzer raises" do
      write_config(<<~YAML)
        grade:
          - name: website-build
            run: npm --prefix website run build
            when_files_changed:
              - "website/**"
          - name: rspec
            run: bin/rspec
      YAML
      stub_changed_files("website/src/index.js")
      register_analyzer { |repo_path:, changed_files:| raise "boom" }

      handler.call

      grader_steps = workflow.steps.where(kind: "grader").order(:position)
      expect(grader_steps.map { |s| s.details["name"] }).to eq(%w[website-build rspec])
      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).to include("affected_test_analyzer").and include("falling back to glob-only")
    end

    it "does not use analyzer-expanded files for the recorded changed-files fingerprint" do
      write_grade_config("bin/rspec")
      stub_changed_files("app/models/user.rb")
      register_analyzer { |repo_path:, changed_files:| [ "spec/models/user_spec.rb" ] }

      handler.call

      expect(workflow.reload.artifact("grade_plan_changed_files")).to eq([ "app/models/user.rb" ])
    end
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

  # --- grade.rerun_only_failed ---------------------------------------------

  describe "grade.rerun_only_failed" do
    def create_prior_grader_step(name:, state:, iteration: 1)
      Step.create!(
        workflow: workflow,
        kind: "grader",
        position: 50,
        iteration: iteration,
        loop_id: loop_id,
        state: state,
        details: { "name" => name, "required" => true }
      )
    end

    def build_iteration_two_handler
      collect2 = Step.create!(workflow: workflow, kind: "grader_collect", position: 202, iteration: 2, loop_id: loop_id)
      fanout2 = Step.create!(workflow: workflow, kind: "grader_fanout", position: 201, iteration: 2, loop_id: loop_id, next_step_id: collect2.id)
      run2 = fanout2.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: fanout2.iteration)
      handler2 = described_class.new(run2)
      fake_ws2 = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path, base_ref: "origin/main")
      allow(handler2).to receive(:workspace).and_return(fake_ws2)
      handler2
    end

    it "runs every active grader on the first iteration even when the flag is on" do
      write_config(<<~YAML)
        grade:
          rerun_only_failed: true
          steps:
            - name: tests
              run: bin/rspec
            - name: lint
              run: bin/rubocop
      YAML

      handler.call

      expect(workflow.steps.where(kind: "grader").map { |s| s.details["name"] }).to match_array(%w[tests lint])
    end

    it "reruns every active grader on later iterations when the flag is off (default)" do
      write_config(<<~YAML)
        grade:
          steps:
            - name: tests
              run: bin/rspec
            - name: lint
              run: bin/rubocop
      YAML
      create_prior_grader_step(name: "tests", state: "failed")
      create_prior_grader_step(name: "lint", state: "succeeded")

      build_iteration_two_handler.call

      expect(workflow.steps.where(kind: "grader", iteration: 2).map { |s| s.details["name"] }).to match_array(%w[tests lint])
    end

    it "only reruns graders that failed the previous iteration when the flag is on" do
      write_config(<<~YAML)
        grade:
          rerun_only_failed: true
          steps:
            - name: tests
              run: bin/rspec
            - name: lint
              run: bin/rubocop
      YAML
      create_prior_grader_step(name: "tests", state: "failed")
      create_prior_grader_step(name: "lint", state: "succeeded")

      build_iteration_two_handler.call

      expect(workflow.steps.where(kind: "grader", iteration: 2).map { |s| s.details["name"] }).to eq([ "tests" ])
      carried_forward = workflow.reload.artifact(described_class::CARRIED_FORWARD_ARTIFACT_KEY)
      expect(carried_forward).to contain_exactly(include("name" => "lint", "required" => true))
    end

    it "still runs a grader that newly matches when_files_changed this iteration, even though it wasn't active last iteration" do
      write_config(<<~YAML)
        grade:
          rerun_only_failed: true
          steps:
            - name: tests
              run: bin/rspec
            - name: docs
              run: bin/docs-check
              when_files_changed:
                - "docs/**"
      YAML
      # "docs" never had a Step in iteration 1 (its glob didn't match then) —
      # rerun_only_failed must not treat "no prior Step" as "already passed".
      create_prior_grader_step(name: "tests", state: "failed")

      handler2 = build_iteration_two_handler
      stub_changed_files("docs/readme.md")
      handler2.call

      expect(workflow.steps.where(kind: "grader", iteration: 2).map { |s| s.details["name"] }).to match_array(%w[tests docs])
    end
  end
end
