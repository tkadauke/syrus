require "rails_helper"

RSpec.describe WorkEngine::Simulation::ScenarioRunner do
  def run_scenario(name, max_ticks: 50)
    described_class.call(
      path: Rails.root.join("spec/fixtures/work_engine_simulations/#{name}.yml"),
      max_ticks: max_ticks
    )
  end

  it "drives a queued initial workflow to an implemented job" do
    result = run_scenario("single_initial_success")

    expect(result).to be_success
    expect(Job.find(result.job_ids.first)).to be_implemented
  end

  it "waits for job dependencies before starting dependent work" do
    result = run_scenario("job_dependency_success")

    expect(result).to be_success
    parent, child = Job.where(id: result.job_ids).order(:id).to_a
    expect(parent).to be_implemented
    expect(child).to be_implemented
    expect(result.events.grep(/#{child.slug}.*active lock/)).to be_empty
  end

  it "allows an approved parent inside the same epic to unblock dependent implementation" do
    result = run_scenario("same_epic_approved_parent_unblocks_child")

    expect(result).to be_success
    parent, child = Job.where(id: result.job_ids).order(:id).to_a
    expect(parent).to be_approved
    expect(child).to be_implemented
  end

  it "treats cross-epic dependency waits as valid waiting when the fixture declares them" do
    result = run_scenario("cross_epic_approved_parent_waits_for_merge")

    expect(result).to be_waiting
    parent, child = Job.where(id: result.job_ids).order(:id).to_a
    expect(parent).to be_approved
    expect(%w[queued blocked_by_epic]).to include(child.state)
    expect(result.wait_reasons.join("\n")).to include(child.slug)
  end

  it "treats operator approval as a valid waiting outcome" do
    result = run_scenario("epic_chain_waits_for_operator_approval")

    expect(result).to be_waiting
    first, second, third = Job.where(id: result.job_ids).order(:id).to_a
    expect(first).to be_implemented
    expect(second).to be_implemented
    expect(third).to be_implemented
    expect(result.wait_reasons.join("\n")).to include(first.slug)
  end

  it "runs same-epic approved chains until the next approval boundary" do
    result = run_scenario("same_epic_approved_chain_runs_to_next_approval")

    expect(result).to be_waiting
    first, second, third = Job.where(id: result.job_ids).order(:id).to_a
    expect(first).to be_approved
    expect(second).to be_implemented
    expect(third).to be_implemented
  end

  it "runs independent jobs in the same epic without serializing them through dependencies" do
    result = run_scenario("parallel_epic_siblings_implement_independently")

    expect(result).to be_success
    jobs = Job.where(id: result.job_ids).order(:id).to_a
    expect(jobs).to all(be_implemented)
  end

  it "keeps downstream epic work waiting while its upstream epic is not landed" do
    result = run_scenario("epic_dependency_waits_for_upstream_epic")

    expect(result).to be_waiting
    upstream, downstream = Job.where(id: result.job_ids).order(:id).to_a
    expect(upstream).to be_approved
    expect(%w[queued blocked_by_epic]).to include(downstream.state)
  end

  it "applies operator approval events and drains an epic merge train" do
    result = run_scenario("epic_merge_train_after_approval_events")

    expect(result).to be_success
    jobs = Job.where(id: result.job_ids).order(:id).to_a
    expect(jobs).to all(be_closed)
    expect(result.events.join("\n")).to include("landing_queue dispatched")
    expect(result.events.join("\n")).to include("merge_train_land")
  end

  it "reproduces JOB-4427 and closes an already-landed failed stack member" do
    result = run_scenario("job_4427_already_landed_stack_rebase")

    expect(result).to be_success
    root, child = Job.where(id: result.job_ids).order(:id).to_a
    expect(root).to be_closed
    expect(root.closure_reason).to eq("pr_merged")
    expect(child).to be_approved
    expect(result.events.join("\n")).to include("stack_auto_rebase")
  end

  {
    "happy_path_single_job_lands" => "auto_merge",
    "happy_path_epic_merge_train_lands" => "merge_train_land",
    "happy_path_job_dependency_dag_lands" => "auto_merge",
    "happy_path_two_epic_dependency_lands" => "merge_train_land",
    "happy_path_epic_with_job_dependencies_lands" => "merge_train_land",
    "happy_path_job_with_epic_dependency_lands" => "auto_merge",
    "happy_path_epic_job_depends_on_external_job_lands" => "merge_train_land"
  }.each do |scenario, expected_event|
    it "drains #{scenario}" do
      result = run_scenario(scenario)

      expect(result).to be_success
      expect(Job.where(id: result.job_ids).pluck(:state)).to all(eq("closed"))
      expect(result.events.join("\n")).to include(expected_event)
    end
  end

  it "normalizes a queued workflow with a failed step and retries it" do
    result = run_scenario("queued_workflow_with_failed_step")

    expect(result).to be_success
    job = Job.find(result.job_ids.first)
    expect(job).to be_implemented
    expect(result.events.join("\n")).to include("queued_workflow_with_failed_step")
    expect(result.events.join("\n")).to include("retry #{job.slug}")
  end

  it "can opt into workspace availability diagnostics" do
    result = run_scenario("workspace_missing_diagnostic", max_ticks: 1)

    expect(result).to be_stuck
    expect(result.events.join("\n")).to include("workspace_missing")
  end

  {
    "queued_step_without_run" => "queued_step_without_run",
    "running_workflow_with_failed_step" => "running_workflow_with_failed_step",
    "worker_died_retries_once" => "retryable_run_failure",
    "zombie_terminal_unit_orphaned_run" => "running_run_without_live_worker_evidence",
    "closed_job_active_work_unit" => "closed_job_active_runtime_work",
    "running_step_with_terminal_run" => "running_step_with_terminal_runs",
    "active_run_on_terminal_step" => "active_run_on_terminal_step",
    "terminal_workflow_active_descendants" => "cleanup_blocked_by_active_descendants",
    "requested_intent_without_active_unit" => "requested_work_intent_without_active_unit"
  }.each do |scenario, expected_event|
    it "recovers #{scenario}" do
      result = run_scenario(scenario)

      expect(result).to be_success
      expect(result.events.join("\n")).to include(expected_event)
    end
  end

  {
    "terminal_work_unit_active_lock" => [ "terminal_work_unit_active_locks", "satisfied" ],
    "active_work_unit_without_workflow" => [ "active_work_unit_without_workflow", "requested" ],
    "succeeded_unit_unsatisfied_intent" => [ "succeeded_work_unit_unsatisfied_intent", "satisfied" ],
    "failed_unit_unfailed_intent" => [ "failed_work_unit_unfailed_intent", "failed" ],
    "waiting_intent_with_active_unit" => [ "waiting_work_intent_with_active_unit", "requested" ],
    "superseded_unit_uncancelled_intent" => [ "superseded_work_unit_uncancelled_intent", "cancelled" ]
  }.each do |scenario, (expected_event, expected_intent_state)|
    it "repairs #{scenario}" do
      result = run_scenario(scenario)

      expect(result).to be_success
      expect(result.events.join("\n")).to include(expected_event)
      expect(WorkIntent.find(result.work_intent_ids.first).state).to eq(expected_intent_state)
    end
  end
end
