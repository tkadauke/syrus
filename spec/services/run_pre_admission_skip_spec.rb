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
        delivery: nil, raw_delivery: nil, approval: nil, external_prs: nil, project: nil, targets: [], target_graph: nil, scripts: {}, merge_train: nil,
        visual_review: SyrusYml::VisualReviewConfig.new(
          enabled: true, rounds: 1,
          when_files_changed: [ "app/frontend/**/*", "plugins/**/app/frontend/**/*" ],
          seed_notes: nil
        )
      )
    )
    allow(App::VisualReviewProjects).to receive(:configured_when_files_changed).with(workspace_path: workspace_path).and_return([])

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

  it "skips retired review_plan steps before host admission" do
    review_step.update!(kind: "review_plan")

    result = described_class.call(run: run)

    expect(result).to be_skip
    expect(result.reason).to eq("review_plan_retired")
    expect(result.message).to eq("[review_plan] retired legacy PR-comment step - skipping")
  end
end
