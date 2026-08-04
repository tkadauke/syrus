require "rails_helper"

RSpec.describe Admin::StuckJobExplainer do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  it "explains fan-in dependency blockers and a queued workflow stale behind a newer terminal workflow" do
    leaf_a = Factories.job_record(user: user, repository: repository, state: "failed", issue_title: "Leaf A")
    leaf_b = Factories.job_record(user: user, repository: repository, state: "failed", issue_title: "Leaf B")
    parent = Factories.job_record(user: user, repository: repository, state: "approved", issue_title: "Parent")
    JobDependency.create!(job: parent, depends_on_job: leaf_a, source: "manual")

    job = Factories.job_record(user: user, repository: repository, state: "queued", issue_title: "Fan-in")
    JobDependency.create!(job: job, depends_on_job: parent, source: "manual")
    JobDependency.create!(job: job, depends_on_job: leaf_a, source: "manual")
    JobDependency.create!(job: job, depends_on_job: leaf_b, source: "manual")

    queued = Workflow.create!(job: job, trigger_kind: "retry", state: "queued", created_at: 20.minutes.ago)
    queued.steps.create!(kind: "prepare", position: 0)
    newer_terminal = Workflow.create!(job: job, trigger_kind: "manual", state: "succeeded", created_at: 5.minutes.ago, finished_at: 4.minutes.ago)
    newer_terminal.steps.create!(kind: "implement", position: 0)

    payload = described_class.call(job.reload, github_client: no_github_client)

    expect(payload.dig(:workflows, :queued).map { |workflow| workflow[:id] }).to include(queued.id)
    expect(payload.dig(:workflows, :latest, :id)).to eq(queued.id)
    expect(payload.dig(:workflows, :latest, :state)).to eq("queued")
    expect(payload.dig(:workflows, :failed).map { |workflow| workflow[:id] }).not_to include(newer_terminal.id)
    expect(payload.dig(:workflows, :queued_stale_behind_terminal)).to be(true)
    expect(payload.dig(:dependencies, :multiple_leaf_dependencies).map { |dep| dep[:job_id] }).to contain_exactly(leaf_a.id, leaf_b.id)
    expect(payload.dig(:dependencies, :redundant_transitive_dependencies)).to contain_exactly(
      include(redundant_job_id: leaf_a.id, reachable_through_job_id: parent.id)
    )
    expect(payload.dig(:recommended_action, :action)).to eq("manual_intervention")
  end

  it "recommends a successful no-change close for an empty reconciliation branch" do
    parent = Factories.job_record(
      user: user,
      repository: repository,
      state: "approved",
      issue_title: "Parent",
      branch_name: "syrus/parent",
      pr_number: 10
    )
    job = Factories.job_record(
      user: user,
      repository: repository,
      state: "implemented",
      issue_title: "Reconcile",
      branch_name: "syrus/reconcile",
      pr_number: 11,
      parent_job: parent
    )
    client = instance_double(
      GithubClient,
      pull_request: pr_with_base("syrus/parent"),
      branch_head_sha: "same-sha",
      commit_tree_sha: "same-tree"
    )

    payload = described_class.call(job, github_client: client)

    expect(payload.dig(:dependencies, :selected_stack_parent)).to include(job_id: parent.id, branch_name: "syrus/parent")
    expect(payload.dig(:dependencies, :pr_base_mismatch)).to include(checked: true, mismatch: false)
    expect(payload.dig(:empty_reconciliation, :evidence)).to include(
      include(kind: "branch_tip_equals_parent_branch", sha: "same-sha"),
      include(kind: "head_tree_equals_effective_parent_tree", tree_sha: "same-tree")
    )
    expect(payload.dig(:recommended_action)).to include(action: "close_successfully_no_changes", closure_reason: "no_changes")
  end

  it "points grader failures at Run logs instead of stack state" do
    job = Factories.job_record(
      user: user,
      repository: repository,
      state: "failed",
      issue_title: "Fix failing grader",
      branch_name: "syrus/grader"
    )
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "failed", failure_reason: "loop_exhausted_after_grader_failure", finished_at: 1.minute.ago)
    step = workflow.steps.create!(kind: "grader", position: 0, state: "failed")
    run = step.runs.create!(job: job, trigger_kind: "initial", state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)
    run.create_run_diagnostic!(error_class: "Steps::Base::StepFailed", error_message: "grader rspec failed")
    run.job_logs.create!(sequence: 0, kind: "grade_log", chunk: "RSpec failed in spec/services/widget_spec.rb")

    payload = described_class.call(job.reload, github_client: no_github_client)

    expect(payload.dig(:workflows, :latest)).to include(id: workflow.id, state: "failed", failure_reason: "loop_exhausted_after_grader_failure")
    expect(payload.dig(:runs, :failed).first).to include(id: run.id, step_kind: "grader")
    expect(payload.dig(:runs, :failed).first.dig(:diagnostic, :error_message)).to eq("grader rspec failed")
    expect(payload.dig(:recommended_action)).to include(action: "inspect_logs", run_id: run.id)
  end

  it "surfaces no-effective CI repair state instead of generic failing-check diagnostics" do
    repository.update!(auto_merge_enabled: true)
    job = Factories.job_record(
      user: user,
      repository: repository,
      state: "approved",
      issue_title: "Fix stuck CI repair",
      branch_name: "syrus/stuck-ci",
      pr_number: 2059,
      last_ci_handled_sha: nil,
      pr_checks_sha: "21379e9",
      pr_checks_state: "failing",
      pr_checks_checked_at: Time.current,
      landing_failure_reason: "#{PollPullRequestJob::NO_EFFECTIVE_CI_REPAIR_REASON} on 21379e9"
    )
    workflow = Workflow.create!(
      job: job,
      trigger_kind: "ci_failure",
      state: "succeeded",
      artifacts: {
        "head_sha" => "21379e9",
        "no_effective_ci_repair" => {
          "head_sha" => "21379e9",
          "checks_state" => "failing",
          "failed_checks" => [ { "name" => "rspec", "html_url" => "https://github.com/acme/widgets/runs/100" } ]
        }
      },
      finished_at: 1.minute.ago
    )

    payload = described_class.call(job.reload, github_client: no_github_client)

    expect(payload.dig(:workflows, :latest)).to include(id: workflow.id, trigger_kind: "ci_failure", state: "succeeded")
    expect(payload.dig(:landing, :queue, :blocked_reason)).to eq(
      { key: "ci_repair_no_effective_change", params: { slug: job.slug } }
    )
    expect(payload.dig(:landing, :no_effective_ci_repair)).to be(true)
    expect(payload.dig(:recommended_action)).to include(
      action: "manual_intervention",
      reason: "CI repair made no effective change and checks are still failing.",
      pr_number: 2059
    )
    expect(payload.dig(:human_summary)).to include("CI repair made no effective change and checks are still failing.")
  end

  it "uses the stack resolver result for fan-in so it does not invent a selected parent" do
    epic = Factories.epic(user: user, repository: repository, state: "in_progress", epic_dependency_policy: "nonlinear")
    job = Factories.job_record(user: user, repository: repository, epic: epic, state: "queued", issue_title: "Fan-in")
    deps = [
      Factories.job_record(user: user, repository: repository, epic: epic, state: "approved", issue_number: 1574, branch_name: "syrus/issue-1574", pr_number: 1574),
      Factories.job_record(user: user, repository: repository, epic: epic, state: "approved", issue_number: 1575, branch_name: "syrus/issue-1575", pr_number: 1575),
      Factories.job_record(user: user, repository: repository, epic: epic, state: "approved", issue_number: 1576, branch_name: "syrus/issue-1576", pr_number: 1576)
    ]
    deps.each_with_index do |dependency, index|
      dependency.runs.create!(trigger_kind: "initial", state: "succeeded", head_sha: (index + 1).to_s * 40)
      JobDependency.create!(job: job, depends_on_job: dependency, source: "manual")
    end
    Workflow.create!(
      job: job,
      trigger_kind: "initial",
      state: "queued",
      artifacts: { "start_blocked_reason" => "stack_fan_in_base_unavailable" }
    ).steps.create!(kind: "prepare", position: 0)

    payload = described_class.call(job.reload, github_client: no_github_client)

    expect(payload.dig(:dependencies, :unsatisfied)).to be_empty
    expect(payload.dig(:dependencies, :selected_stack_parent)).to be_nil
    expect(payload.dig(:dependencies, :stack_resolution)).to include(
      ready: false,
      reason: "stack_fan_in_base_unavailable"
    )
    expect(payload.dig(:dependencies, :stack_resolution, :blocker, "dependencies").map { |dependency| dependency["job_id"] }).to contain_exactly(*deps.map(&:id))
    expect(payload.dig(:recommended_action, :action)).to eq("manual_intervention")
  end

  def pr_with_base(ref)
    Struct.new(:base).new(Struct.new(:ref).new(ref))
  end

  def no_github_client
    instance_double(GithubClient).tap do |client|
      allow(client).to receive(:pull_request).and_raise(Octokit::NotFound)
      allow(client).to receive(:branch_head_sha).and_raise(Octokit::NotFound)
      allow(client).to receive(:respond_to?).with(:commit_tree_sha).and_return(true)
      allow(client).to receive(:commit_tree_sha).and_raise(Octokit::NotFound)
    end
  end
end
