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

  it "recommends releasing the landing slot for a queued zero-run auto-merge admission block" do
    job = Factories.job_record(
      user: user,
      repository: repository,
      state: "landing",
      issue_number: 2242,
      pr_number: 2181,
      branch_name: "syrus/issue-2242",
      pr_checks_state: "passing",
      github_mergeable_state: "clean",
      github_mergeable: true,
      local_mergeable: true,
      local_mergeable_state: "clean",
      commits_behind_base: 0,
      approved_at: 2.minutes.ago,
      approved_via: "operator"
    )
    workflow = Workflows::AutoMerge.instantiate(job: job)
    workflow.update!(
      created_at: 5.minutes.ago,
      updated_at: 5.minutes.ago,
      artifacts: {
        "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
        "start_blocked_details" => { "reason" => "predicted_budget_pressure_high" },
        "start_blocked_next_check_at" => 3.minutes.from_now.iso8601
      }
    )

    payload = described_class.call(job.reload, github_client: no_github_client)

    expect(payload.dig(:workflows, :latest)).to include(
      id: workflow.id,
      state: "queued",
      trigger_kind: "auto_merge",
      run_count: 0,
      start_blocked_reason: StepDispatcher::ADMISSION_BLOCK_REASON
    )
    expect(payload.dig(:recommended_action, :action)).to eq("release_landing_slot")
    expect(payload.dig(:recommended_action, :workflow_id)).to eq(workflow.id)
    expect(payload.dig(:recommended_action, :reason)).to include("admission-blocked")
    expect(payload.dig(:recommended_action, :reason)).not_to include("Dependency graph")
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

  it "recommends state reconciliation over stale failed-run logs when a queued Job has a ready PR" do
    job = Factories.job_record(
      user: user,
      repository: repository,
      state: "queued",
      issue_title: "Ready PR drift",
      branch_name: "syrus/direct-2415",
      pr_number: 2174,
      pr_checks_state: "passing",
      commits_behind_base: 0,
      github_mergeable_state: "clean"
    )
    published = Workflow.create!(
      job: job,
      trigger_kind: "retry",
      state: "succeeded",
      started_at: 30.minutes.ago,
      finished_at: 25.minutes.ago,
      artifacts: { "publication_branch" => "syrus/direct-2415" }
    )
    published.steps.create!(kind: "pr_open", position: 0, state: "succeeded")
    failed = Workflow.create!(job: job, trigger_kind: "retry", state: "failed", finished_at: 10.minutes.ago)
    failed_step = failed.steps.create!(kind: "grader", position: 0, state: "failed")
    failed_run = failed_step.runs.create!(job: job, trigger_kind: "retry", state: "failed", finished_at: 10.minutes.ago)
    failed_run.create_run_diagnostic!(error_class: "Steps::Base::StepFailed", error_message: "grader rspec failed")
    failed_run.job_logs.create!(sequence: 0, kind: "grade_log", chunk: "RSpec failed")
    latest = Workflow.create!(
      job: job,
      trigger_kind: "retry",
      state: "cancelled",
      started_at: 5.minutes.ago,
      finished_at: 1.minute.ago,
      artifacts: { "retry_cancelled_reason" => "stale_auto_retry" }
    )
    latest.steps.create!(kind: "prepare", position: 0, state: "cancelled")

    payload = described_class.call(job.reload, github_client: no_github_client)

    expect(payload.dig(:workflows, :latest)).to include(id: latest.id, state: "cancelled")
    expect(payload.dig(:recommended_action)).to include(
      action: "reconcile_job_state",
      target_state: "implemented",
      workflow_id: latest.id
    )
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
      Factories.legacy_job_dependency(job: job, depends_on_job: dependency)
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

  it "explains every approved Epic child as waiting for the merge train" do
    repository.update!(auto_merge_enabled: true)
    AppSetting.current.update!(merge_train_enabled: true)
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    reconciliation = Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      kind: "direct",
      issue_number: nil,
      issue_title: "Reconciliation: Historical Epic",
      state: "approved",
      pr_number: 2166,
      branch_name: "syrus/direct-reconciliation",
      pr_checks_state: "passing",
      github_mergeable_state: "clean",
      github_mergeable: true,
      local_mergeable: true,
      local_mergeable_state: "clean",
      approved_at: 1.minute.ago
    )
    payload = described_class.call(reconciliation, github_client: no_github_client)

    expect(payload.dig(:landing, :queue)).to include(
      eligible: false,
      blocked_reason: { key: "waiting_epic_merge_train" }
    )
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
