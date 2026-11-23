require "rails_helper"

RSpec.describe RunPreAdmissionSkip do
  let(:job) { Factories.job(issue_title: "Add search UI", issue_body: "Update search filters.") }
  let(:workflow) { job.workflows.last }
  let(:implement_step) { workflow.steps.find_by!(kind: "implement") }
  let(:implement_run) do
    Run.create!(job: job, step: implement_step, trigger_kind: "initial", state: "succeeded")
  end
  let(:review_step) do
    Step.create!(
      workflow: workflow,
      kind: "visual_review",
      position: 100,
      iteration: 1,
      state: "queued"
    )
  end
  let(:run) { Run.create!(job: job, step: review_step, trigger_kind: "initial", state: "queued") }
  let(:workspace_path) { Rails.root.join("tmp", "run_pre_admission_skip_spec", SecureRandom.hex(6)) }

  before do
    FileUtils.mkdir_p(workspace_path.join(".git"))
    allow(WorkflowWorkspace).to receive(:path_for).with(workflow).and_return(workspace_path)
    allow(SyrusYml).to receive(:load_repo).with(workspace_path).and_return(
      SyrusYml::Config.new(
        prepare: nil, grade: nil, hooks: nil, adversarial_review: nil, review_notes: nil, agent_insight: nil,
        coverage: nil, formatters: [], generated: [], deployment_stages: [], preview: nil, review_plan: false, deploy: nil,
        delivery: nil, raw_delivery: nil, approval: nil, external_prs: nil, merge_train: nil, project: nil, targets: [], target_graph: nil, scripts: {},
        visual_review: SyrusYml::VisualReviewConfig.new(
          enabled: true, rounds: 1,
          when_files_changed: [ "{app/frontend,plugins/global_search/app/frontend}/**/*" ],
          seed_notes: nil, required: false
        )
      )
    )
    allow(App::VisualReviewProjects).to receive(:configured_when_files_changed).with(workspace_path: workspace_path).and_return([])

    # The fake workspace has no real repository, so the cumulative diff is
    # unavailable by default and the per-step diff fallback is exercised.
    allow(GitRunner).to receive(:new).and_return(
      instance_double(GitRunner).tap do |git|
        allow(git).to receive(:run).and_raise(GitRunner::GitError.new(%w[diff], 128, "fatal: not a git repository"))
      end
    )

    implement_step.update!(state: "succeeded")
  end

  after do
    FileUtils.rm_rf(workspace_path.dirname)
  end

  it "admits visual review when the full job diff matches even if the latest scoped diff does not" do
    implement_run.update!(
      agent_diff: <<~DIFF,
        diff --git a/plugins/global_search/app/frontend/routes/Search.tsx b/plugins/global_search/app/frontend/routes/Search.tsx
        +<SearchFilters />
        diff --git a/app/services/search_filter.rb b/app/services/search_filter.rb
        +filter
      DIFF
      step_agent_diff: <<~DIFF
        diff --git a/app/services/search_filter.rb b/app/services/search_filter.rb
        +filter
      DIFF
    )

    result = described_class.call(run: run)

    expect(result).not_to be_skip
  end

  it "admits visual review for a file directly inside a brace-expanded pattern directory" do
    implement_run.update!(
      agent_diff: <<~DIFF
        diff --git a/app/frontend/index.ts b/app/frontend/index.ts
        +export const search = true
      DIFF
    )

    result = described_class.call(run: run)

    expect(result).not_to be_skip
  end

  it "admits visual review from the cumulative branch diff when the latest iteration only touched docs" do
    docs_diff = "diff --git a/docs/readme.md b/docs/readme.md\n+docs\n"
    implement_run.update!(agent_diff: docs_diff, step_agent_diff: docs_diff)
    git = instance_double(GitRunner)
    allow(GitRunner).to receive(:new).and_return(git)
    allow(WorkflowWorkspace).to receive(:base_ref_for).with(job, workflow: workflow).and_return("origin/parent-branch")
    expect(git).to receive(:run)
      .with("-c", "core.quotePath=false", "diff", "--name-only", "origin/parent-branch...HEAD", chdir: workspace_path.to_s)
      .and_return("app/frontend/routes/Search.tsx\ndocs/readme.md\n")

    expect(described_class.call(run: run)).not_to be_skip
  end

  it "skips when the cumulative branch diff has no matching files" do
    git = instance_double(GitRunner)
    allow(GitRunner).to receive(:new).and_return(git)
    allow(git).to receive(:run).and_return("docs/readme.md\n")

    expect(described_class.call(run: run)).to be_skip
  end

  it "skips retired review_plan steps before host admission" do
    review_step.update!(kind: "review_plan")

    result = described_class.call(run: run)

    expect(result).to be_skip
    expect(result.reason).to eq("review_plan_retired")
    expect(result.message).to eq("[review_plan] retired legacy PR-comment step - skipping")
  end
end
