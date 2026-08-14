require "rails_helper"

RSpec.describe "Work engine reconciler chaos simulation" do
  include ActiveJob::TestHelper

  CaseExpectation = Data.define(
    :label,
    :target,
    :expected_issue,
    :expected_action,
    :expected_issues,
    :expected_actions,
    :forbidden_issues,
    :forbidden_actions,
    :required_plans,
    :forbidden_plans,
    :forbidden_workflow_issues,
    :stale_auto_retry_workflow_ids,
    :trace
  ) do
    def initialize(label:, target:, expected_issue: nil, expected_action: nil, expected_issues: [], expected_actions: [], forbidden_issues: [], forbidden_actions: [],
                   required_plans: [], forbidden_plans: [], forbidden_workflow_issues: [], stale_auto_retry_workflow_ids: [], trace: [])
      super(
        label: label,
        target: target,
        expected_issue: expected_issue&.to_s,
        expected_action: expected_action&.to_s,
        expected_issues: Array(expected_issues).map(&:to_s),
        expected_actions: Array(expected_actions).map(&:to_s),
        forbidden_issues: forbidden_issues.map(&:to_s),
        forbidden_actions: forbidden_actions.map(&:to_s),
        required_plans: required_plans.map { |action, target| [ action.to_s, target.class.name, target.id ] },
        forbidden_plans: forbidden_plans.map { |action, target| [ action.to_s, target.class.name, target.id ] },
        forbidden_workflow_issues: forbidden_workflow_issues.map { |kind, workflow| [ kind.to_s, workflow.id ] },
        stale_auto_retry_workflow_ids: Array(stale_auto_retry_workflow_ids).map(&:id),
        trace: trace
      )
    end
  end

  class ReconcilerChaosSimulation
    attr_reader :seed, :live_worker_hosts

    SCENARIOS = %i[
      queued_without_queue_claim
      queued_failed_solid_queue_execution
      queued_dead_resume_queue
      queued_with_healthy_queue_job_beside_dead_resume_job
      inline_successor_owned_by_live_root_job
      stale_auto_retry_workflow_with_queued_run
      stale_auto_retry_after_branch_divergence_recovery
      epic_workflow_conflict
      queued_job_after_epic_workflow_conflict
      queued_job_after_cancelled_workflow
      stale_branch_diverged_workflow
      recovered_branch_diverged_failed_job
      closed_job_with_active_workflow
      queued_step_without_run_after_succeeded_step
      running_step_with_failed_terminal_run
      running_step_with_succeeded_terminal_run
      stale_running_run_without_worker_evidence
      fresh_running_run
      missing_local_workspace
      missing_remote_live_worker_workspace
      stale_main_broken_artifact_after_recovery
      active_main_health_start_block
      recovered_main_health_start_block
      expired_dependency_start_block
      orphaned_landing_job
      running_workflow_without_active_descendants
      running_workflow_with_failed_step
      terminal_workflow_with_active_descendants
    ].freeze

    TOPOLOGY_DEGRADATIONS = %i[
      topology_queued_without_queue_claim
      topology_queued_failed_solid_queue_execution
      topology_queued_dead_resume_queue
      topology_closed_job_with_active_workflow
      topology_queued_step_without_run_after_succeeded_step
      topology_running_step_with_failed_terminal_run
      topology_running_step_with_succeeded_terminal_run
      topology_stale_running_run_without_worker_evidence
      topology_missing_local_workspace
      topology_terminal_workflow_with_active_descendant
    ].freeze

    def initialize(seed:, spec_context:)
      @seed = seed
      @random = Random.new(seed)
      @spec_context = spec_context
      @case_number = 0
      @live_worker_hosts = Set.new
    end

    def next_case
      @case_number += 1
      @trace = [ "seed=#{seed}", "case=#{@case_number}" ]
      @live_worker_hosts.clear
      clear_solid_queue

      scenario = SCENARIOS.sample(random: @random)
      @trace << "scenario=#{scenario}"
      send(scenario)
    end

    def empty_topology_case
      @case_number += 1
      @trace = [ "seed=#{seed}", "case=#{@case_number}", "mode=topology", "mutations=none" ]
      @live_worker_hosts.clear
      clear_solid_queue
      reset_shared_repository!

      job = Factories.job(
        user: shared_user,
        repository: shared_repository,
        issue_number: 10_000 + case_number,
        agent_provider: random_provider
      )
      trace << "job=#{job.id}"

      expectation("empty topology reconciler graph", target: { job_id: job.id })
    end

    def next_topology_case
      @case_number += 1
      @trace = [ "seed=#{seed}", "case=#{@case_number}", "mode=topology" ]
      @live_worker_hosts.clear
      clear_solid_queue
      reset_shared_repository!

      entry = Workflow::TriggerKind::ENTRIES.sample(random: random)
      workflow = materialized_random_workflow(entry)
      step = workflow.steps.order(:position, :id).sample(random: random)
      degradation = TOPOLOGY_DEGRADATIONS.sample(random: random)
      trace << "workflow_entry=#{entry.kind} template=#{entry.template} workflow=#{workflow.id} actual_trigger=#{workflow.trigger_kind}"
      trace << "selected_step=#{step.id}:#{step.kind}:position=#{step.position}:iteration=#{step.iteration}:loop=#{step.loop_id || "none"}"
      trace << "degradation=#{degradation}"

      send(degradation, workflow, step)
    end

    def live_worker?(hostname)
      live_worker_hosts.include?(hostname)
    end

    private

    attr_reader :random, :spec_context, :case_number, :trace

    def clear_solid_queue
      spec_context.clear_solid_queue_test_tables!
      trace << "solid_queue=cleared"
    end

    def graph
      reset_shared_repository!
      job = Factories.job(
        user: shared_user,
        repository: shared_repository,
        issue_number: case_number,
        agent_provider: random_provider
      )
      workflow = job.latest_workflow
      step = workflow.first_step
      run = step.runs.first
      trace << "job=#{job.id} workflow=#{workflow.id} step=#{step.id} run=#{run.id}"
      [ job, workflow, step, run ]
    end

    def shared_user
      @shared_user ||= Factories.user
    end

    def shared_repository
      @shared_repository ||= Factories.repository(user: shared_user)
    end

    def reset_shared_repository!
      shared_repository.update!(
        main_branch_health_enabled: true,
        ci_health: "healthy",
        grader_health: "healthy",
        landing_paused: false
      )
    end

    def random_provider
      random.rand(2).zero? ? "claude" : "codex"
    end

    def old_active_age
      (ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD + random.rand(1..6).minutes)
    end

    def stale_heartbeat_age
      Run::STALE_HEARTBEAT_THRESHOLD + random.rand(1..10).minutes
    end

    def queued_run!(workflow, step, run, age: old_active_age)
      workflow.update_columns(state: "running", started_at: age.ago)
      step.update_columns(state: "queued", created_at: age.ago, updated_at: age.ago)
      run.update_columns(state: "queued", created_at: age.ago, updated_at: age.ago)
      trace << "run=#{run.id}:queued age=#{age.inspect}"
    end

    def running_run!(workflow, step, run, heartbeat_age:)
      workflow.update_columns(state: "running", started_at: heartbeat_age.ago)
      step.update_columns(state: "running", started_at: heartbeat_age.ago)
      run.update_columns(
        state: "running",
        started_at: heartbeat_age.ago,
        last_heartbeat_at: heartbeat_age.ago
      )
      trace << "run=#{run.id}:running heartbeat_age=#{heartbeat_age.inspect}"
    end

    def finished_run!(workflow, step, run)
      workflow.update_columns(state: "running", started_at: 6.minutes.ago)
      step.update_columns(state: "queued", updated_at: 5.minutes.ago)
      run.update_columns(state: "succeeded", finished_at: 5.minutes.ago)
      trace << "run=#{run.id}:succeeded"
    end

    def remove_first_run!(workflow, run)
      run.destroy!
      workflow.update_columns(state: "queued", created_at: 5.minutes.ago, updated_at: 5.minutes.ago)
      trace << "workflow=#{workflow.id}:queued_without_first_run"
    end

    def solid_queue_run_job(run, ready: false, claimed: false, failed: false, queue_name: "runs", worker_host: "worker-live", live_process: true)
      created_at = 15.minutes.ago
      queue_job = SolidQueue::Job.create!(
        class_name: "RunJob",
        queue_name: queue_name,
        priority: 10,
        arguments: { "arguments" => [ run.id ] },
        created_at: created_at,
        updated_at: created_at
      )
      SolidQueue::ReadyExecution.create!(job: queue_job, priority: 10, queue_name: queue_name, created_at: created_at) if ready
      if claimed
        process = SolidQueue::Process.create!(
          hostname: worker_host,
          kind: "worker",
          last_heartbeat_at: live_process ? 10.seconds.ago : 20.minutes.ago,
          metadata: {},
          name: "#{worker_host}:#{queue_job.id}",
          pid: 1000 + queue_job.id,
          created_at: created_at
        )
        SolidQueue::ClaimedExecution.create!(job: queue_job, process_id: process.id, created_at: created_at)
      end
      SolidQueue::FailedExecution.create!(job: queue_job, error: "chaos failed execution", created_at: 1.minute.ago) if failed
      trace << "sq_job=#{queue_job.id} run=#{run.id} queue=#{queue_name} ready=#{ready} claimed=#{claimed} failed=#{failed}"
      queue_job
    end

    def missing_workspace!(workflow)
      matcher = spec_context.receive(:directory?)
        .with(WorkflowWorkspace.path_for(workflow))
        .and_return(false)
      spec_context.allow(File).to(matcher)
      trace << "workspace=#{workflow.id}:missing"
    end

    def fresh_retry_workflow(job)
      workflow = Workflows::Retry.instantiate(job: job, agent_provider: job.agent_provider)
      workflow.update_columns(created_at: random.rand(6..15).minutes.ago, updated_at: random.rand(6..15).minutes.ago)
      step = workflow.first_step
      trace << "workflow=#{workflow.id}:fresh_retry step=#{step.id}"
      [ workflow, step ]
    end

    def start_with_queued_run!(job)
      workflow, step = fresh_retry_workflow(job)
      run = StepDispatcher.start_workflow(workflow)
      queued_run!(workflow.reload, step.reload, run.reload)
      [ workflow, step, run ]
    end

    def materialized_random_workflow(entry)
      AppSetting.current.update!(
        adversarial_review_rounds: random.rand(0..2),
        grade_max_iterations: 3
      )
      job = Factories.job_record(
        user: shared_user,
        repository: shared_repository,
        issue_number: 30_000 + case_number,
        state: "queued",
        agent_provider: random_provider
      )
      workflow = entry.template_class.instantiate(job: job, agent_provider: job.agent_provider)
      workflow.update_columns(state: "running", started_at: random.rand(6..12).minutes.ago)

      expand_adversarial_review_loops!(workflow)
      expand_try_branches!(workflow)
      expand_grader_retry_loops!(workflow)
      workflow.reload
    end

    def expand_adversarial_review_loops!(workflow)
      review = workflow.steps.where(kind: "adversarial_review", iteration: 1).order(:position).first
      return unless review && random.rand(2).zero?

      max_extra_iterations = random.rand(0..1)
      max_extra_iterations.times do
        current_review = workflow.reload.steps.where(kind: "adversarial_review", loop_id: review.loop_id).order(:iteration).last
        current_review.update_columns(state: "succeeded", finished_at: 4.minutes.ago)
        StepDispatcher.advance_from(current_review)
      end
    end

    def expand_try_branches!(workflow)
      workflow.steps.order(:position).to_a.each do |step|
        next unless step.details.to_h["try_id"].present?
        next unless random.rand(2).zero?

        failure_code =
          case step.kind
          when "push"
            "remote_branch_advanced_rebase_conflict"
          when "merge_train_land"
            Steps::MergeTrainLand::BaseMoved::FAILURE_CODE
          end
        next unless failure_code

        step.update!(details: step.details.to_h.merge("failure_code" => failure_code))
        StepDispatcher.fail_from(step)
      end
    end

    def expand_grader_retry_loops!(workflow)
      workflow.steps.where(kind: "grader_fanout").order(:position).to_a.each do |fanout|
        next unless fanout.reload.persisted?
        next if workflow.steps.where(kind: "grader", loop_id: fanout.loop_id, iteration: fanout.iteration).exists?

        if fanout.loop_id.blank?
          insert_dynamic_grader_steps!(workflow, loop_id: nil, iteration: fanout.iteration, count: random.rand(1..4))
          next
        end

        desired_iterations = random.rand(1..3)
        current_iteration = fanout.iteration
        loop_id = fanout.loop_id
        loop do
          insert_dynamic_grader_steps!(workflow, loop_id: loop_id, iteration: current_iteration, count: random.rand(1..4))
          break if current_iteration >= desired_iterations

          collect = workflow.steps.find_by!(kind: "grader_collect", loop_id: loop_id, iteration: current_iteration)
          StepDispatcher.fail_from(collect)
          current_iteration += 1
        end
      end
    end

    def insert_dynamic_grader_steps!(workflow, loop_id:, iteration:, count:)
      fanout = workflow.steps.find_by!(kind: "grader_fanout", loop_id: loop_id, iteration: iteration)
      collect = workflow.steps.find_by!(kind: "grader_collect", loop_id: loop_id, iteration: iteration)
      return unless fanout && collect
      return if workflow.steps.where(kind: "grader", loop_id: loop_id, iteration: iteration).exists?

      insertion_position = fanout.position + 1
      workflow.steps.where("position >= ?", insertion_position).update_all([ "position = position + ?", count ])

      graders = count.times.map do |index|
        Step.create!(
          workflow: workflow,
          kind: "grader",
          position: insertion_position + index,
          iteration: iteration,
          loop_id: loop_id,
          details: { "name" => "topology-grader-#{iteration}-#{index + 1}", "required" => true }
        )
      end

      ([ fanout ] + graders + [ collect ]).each_cons(2) { |step, next_step| step.update!(next_step_id: next_step.id) }
      trace << "grader_loop=#{loop_id}:iteration=#{iteration}:graders=#{count}"
    end

    def topology_queued_without_queue_claim(workflow, step)
      run = queued_run_on_step!(workflow, step)
      expectation(
        "topology queued run without queue claim",
        target: { workflow_id: workflow.id },
        expected_issue: :queued_run_without_queue_claim,
        expected_action: :reenqueue_run,
        required_plans: [ [ :reenqueue_run, run ] ]
      )
    end

    def topology_queued_failed_solid_queue_execution(workflow, step)
      run = queued_run_on_step!(workflow, step)
      solid_queue_run_job(run, failed: true)
      expectation(
        "topology queued run with failed Solid Queue execution",
        target: { workflow_id: workflow.id },
        expected_issue: :queued_run_solid_queue_failed_execution,
        expected_action: :reenqueue_run,
        required_plans: [ [ :reenqueue_run, run ] ]
      )
    end

    def topology_queued_dead_resume_queue(workflow, step)
      run = queued_run_on_step!(workflow, step)
      storage_key = "chaos-topology-dead-storage-#{case_number}-#{workflow.id}"
      workflow.update_columns(worker_storage_key: storage_key)
      solid_queue_run_job(run, ready: true, queue_name: "resume-#{storage_key}")
      expectation(
        "topology queued run on dead resume queue",
        target: { workflow_id: workflow.id },
        expected_issue: :queued_run_on_dead_resume_queue,
        expected_action: :reenqueue_run,
        required_plans: [ [ :reenqueue_run, run ] ]
      )
    end

    def topology_stale_running_run_without_worker_evidence(workflow, step)
      run = running_run_on_step!(workflow, step, heartbeat_age: stale_heartbeat_age)
      expectation(
        "topology stale running run without worker evidence",
        target: { workflow_id: workflow.id },
        expected_issue: :running_run_without_live_worker_evidence,
        required_plans: []
      )
    end

    def topology_closed_job_with_active_workflow(workflow, step)
      running_run_on_step!(workflow, step, heartbeat_age: stale_heartbeat_age)
      workflow.job.update_columns(state: "closed", finished_at: 10.minutes.ago, closure_reason: "operator_cancelled")
      expectation(
        "topology closed job with active workflow",
        target: { workflow_id: workflow.id },
        expected_issue: :closed_job_active_workflow,
        expected_action: :cancel_workflow_for_closed_job,
        required_plans: [ [ :cancel_workflow_for_closed_job, workflow ] ],
        forbidden_issues: %i[running_run_without_live_worker_evidence queued_run_without_queue_claim retryable_run_failure],
        forbidden_actions: %i[reenqueue_run mark_worker_died mark_worker_died_and_retry_failed_step mark_worker_died_and_retry_workflow]
      )
    end

    def topology_queued_step_without_run_after_succeeded_step(workflow, step)
      queued_step = queued_successor_without_run!(workflow, step)
      expectation(
        "topology queued step without run after succeeded predecessor",
        target: { workflow_id: workflow.id },
        expected_issue: :queued_step_without_run,
        expected_action: :resume_queued_step,
        required_plans: [ [ :resume_queued_step, queued_step ] ],
        forbidden_actions: %i[reenqueue_run start_workflow]
      )
    end

    def topology_running_step_with_failed_terminal_run(workflow, step)
      run = failed_terminal_run_on_running_step!(workflow, step)
      expectation(
        "topology running step with failed terminal run",
        target: { workflow_id: workflow.id },
        expected_issue: :running_step_with_terminal_runs,
        expected_action: :reconcile_step_from_terminal_run,
        required_plans: [ [ :reconcile_step_from_terminal_run, step ] ],
        forbidden_issues: %i[retryable_run_failure nonretryable_semantic_git_failure]
      )
    end

    def topology_running_step_with_succeeded_terminal_run(workflow, step)
      run = succeeded_terminal_run_on_running_step!(workflow, step)
      expectation(
        "topology running step with succeeded terminal run",
        target: { workflow_id: workflow.id },
        expected_issue: :running_step_with_terminal_runs,
        expected_action: :reconcile_step_from_terminal_run,
        required_plans: [ [ :reconcile_step_from_terminal_run, step ] ],
        forbidden_issues: %i[retryable_run_failure nonretryable_semantic_git_failure],
        forbidden_plans: [ [ :retry_failed_step, run ], [ :retry_workflow, workflow ] ]
      )
    end

    def topology_missing_local_workspace(workflow, step)
      running_run_on_step!(workflow, step, heartbeat_age: random.rand(10..50).seconds)
      missing_workspace!(workflow)
      expectation(
        "topology missing local workspace",
        target: { workflow_id: workflow.id },
        expected_issue: :workspace_missing,
        expected_action: :operator_review_missing_workspace
      )
    end

    def topology_terminal_workflow_with_active_descendant(workflow, step)
      deactivate_other_descendants!(workflow, except_step: step)
      run = running_run_on_step!(workflow, step, heartbeat_age: random.rand(10..50).seconds)
      Run.where(step_id: workflow.steps.select(:id))
         .where.not(id: run.id)
         .where(state: %w[queued running])
         .update_all(state: "succeeded", finished_at: 4.minutes.ago)
      workflow.update_columns(state: "failed", finished_at: 5.minutes.ago, cleaned_up_at: nil)
      expectation(
        "topology terminal workflow with active descendant",
        target: { workflow_id: workflow.id },
        expected_issue: :cleanup_blocked_by_active_descendants,
        expected_action: :operator_review_active_descendants
      )
    end

    def queued_run_on_step!(workflow, step)
      age = old_active_age
      Run.where(step_id: step.id).delete_all
      workflow.update_columns(state: "running", started_at: age.ago)
      step.update_columns(state: "queued", started_at: nil, finished_at: nil, created_at: age.ago, updated_at: age.ago)
      run = step.runs.create!(
        job: workflow.job,
        user: workflow.job.user,
        trigger_kind: workflow.trigger_kind,
        agent_provider: workflow.agent_provider,
        state: "queued",
        iteration: step.iteration,
        created_at: age.ago,
        updated_at: age.ago
      )
      trace << "run=#{run.id}:topology_queued step=#{step.kind} age=#{age.inspect}"
      run
    end

    def running_run_on_step!(workflow, step, heartbeat_age:)
      Run.where(step_id: step.id).delete_all
      workflow.update_columns(state: "running", started_at: heartbeat_age.ago)
      step.update_columns(state: "running", started_at: heartbeat_age.ago, finished_at: nil)
      run = step.runs.create!(
        job: workflow.job,
        user: workflow.job.user,
        trigger_kind: workflow.trigger_kind,
        agent_provider: workflow.agent_provider,
        state: "running",
        iteration: step.iteration,
        started_at: heartbeat_age.ago,
        last_heartbeat_at: heartbeat_age.ago
      )
      trace << "run=#{run.id}:topology_running step=#{step.kind} heartbeat_age=#{heartbeat_age.inspect}"
      run
    end

    def queued_successor_without_run!(workflow, predecessor)
      age = old_active_age
      successor = predecessor.next_step
      unless successor
        successor = Step.create!(
          workflow: workflow,
          kind: "pr_open",
          position: predecessor.position + 1,
          iteration: predecessor.iteration
        )
        predecessor.update!(next_step: successor)
      end

      Run.where(step_id: predecessor.id).delete_all
      Run.where(step_id: successor.id).delete_all
      workflow.update_columns(state: "running", started_at: age.ago)
      predecessor.update_columns(state: "succeeded", started_at: age.ago, finished_at: (age - 1.minute).ago, updated_at: (age - 1.minute).ago)
      predecessor.runs.create!(
        job: workflow.job,
        user: workflow.job.user,
        trigger_kind: workflow.trigger_kind,
        agent_provider: workflow.agent_provider,
        state: "succeeded",
        iteration: predecessor.iteration,
        started_at: age.ago,
        finished_at: (age - 1.minute).ago,
        created_at: age.ago,
        updated_at: (age - 1.minute).ago
      )
      successor.update_columns(state: "queued", started_at: nil, finished_at: nil, created_at: age.ago, updated_at: age.ago)
      trace << "step=#{successor.id}:queued_without_run predecessor=#{predecessor.id}:#{predecessor.kind} age=#{age.inspect}"
      successor
    end

    def failed_terminal_run_on_running_step!(workflow, step)
      age = old_active_age
      Run.where(step_id: step.id).delete_all
      workflow.update_columns(state: "running", started_at: age.ago)
      step.update_columns(state: "running", started_at: age.ago, finished_at: nil, updated_at: age.ago)
      run = step.runs.create!(
        job: workflow.job,
        user: workflow.job.user,
        trigger_kind: workflow.trigger_kind,
        agent_provider: workflow.agent_provider,
        state: "failed",
        iteration: step.iteration,
        started_at: age.ago,
        last_heartbeat_at: age.ago,
        finished_at: age.ago,
        created_at: age.ago,
        updated_at: age.ago
      )
      RunFailureClassification.create!(
        run: run,
        classification: "database_connection_error",
        retryable: true,
        confidence: 0.9,
        reason: "chaos terminal run on running step",
        classified_at: age.ago
      )
      trace << "run=#{run.id}:failed_terminal_on_running_step step=#{step.kind} age=#{age.inspect}"
      run
    end

    def succeeded_terminal_run_on_running_step!(workflow, step)
      age = old_active_age
      Run.where(step_id: step.id).delete_all
      workflow.update_columns(state: "running", started_at: age.ago)
      step.update_columns(state: "running", started_at: age.ago, finished_at: nil, updated_at: age.ago)
      run = step.runs.create!(
        job: workflow.job,
        user: workflow.job.user,
        trigger_kind: workflow.trigger_kind,
        agent_provider: workflow.agent_provider,
        state: "succeeded",
        iteration: step.iteration,
        started_at: age.ago,
        last_heartbeat_at: age.ago,
        finished_at: age.ago,
        created_at: age.ago,
        updated_at: age.ago
      )
      trace << "run=#{run.id}:succeeded_terminal_on_running_step step=#{step.kind} age=#{age.inspect}"
      run
    end

    def deactivate_other_descendants!(workflow, except_step:)
      workflow.steps.where.not(id: except_step.id).where(state: %w[queued running]).update_all(
        state: "succeeded",
        finished_at: 4.minutes.ago
      )
      Run.where(step_id: workflow.steps.where.not(id: except_step.id).select(:id))
         .where(state: %w[queued running])
         .update_all(state: "succeeded", finished_at: 4.minutes.ago)
    end

    def queued_without_queue_claim
      _job, workflow, step, run = graph
      queued_run!(workflow, step, run)

      expectation(
        "queued run with no queue claim",
        target: { run_id: run.id },
        expected_issue: :queued_run_without_queue_claim,
        expected_action: :reenqueue_run
      )
    end

    def queued_failed_solid_queue_execution
      _job, workflow, step, run = graph
      queued_run!(workflow, step, run)
      solid_queue_run_job(run, failed: true)

      expectation(
        "queued run with failed Solid Queue execution",
        target: { run_id: run.id },
        expected_issue: :queued_run_solid_queue_failed_execution,
        expected_action: :reenqueue_run
      )
    end

    def queued_dead_resume_queue
      _job, workflow, step, run = graph
      storage_key = "chaos-dead-storage-#{case_number}"
      queued_run!(workflow, step, run)
      workflow.update_columns(worker_storage_key: storage_key)
      solid_queue_run_job(run, ready: true, queue_name: "resume-#{storage_key}")

      expectation(
        "queued run on dead resume queue",
        target: { run_id: run.id },
        expected_issue: :queued_run_on_dead_resume_queue,
        expected_action: :reenqueue_run
      )
    end

    def queued_with_healthy_queue_job_beside_dead_resume_job
      _job, workflow, step, run = graph
      storage_key = "chaos-dead-storage-#{case_number}"
      queued_run!(workflow, step, run)
      workflow.update_columns(worker_storage_key: storage_key)
      solid_queue_run_job(run, ready: true, queue_name: "resume-#{storage_key}")
      solid_queue_run_job(run, ready: true, queue_name: "runs")

      expectation(
        "queued run with healthy queue job beside dead resume job",
        target: { run_id: run.id },
        forbidden_issues: %i[queued_run_on_dead_resume_queue queued_run_solid_queue_failed_execution queued_run_without_queue_claim],
        forbidden_actions: %i[reenqueue_run]
      )
    end

    def inline_successor_owned_by_live_root_job
      job, workflow, step, root_run = graph
      finished_run!(workflow, step, root_run)
      successor = step.runs.create!(
        job: job,
        user: job.user,
        trigger_kind: workflow.trigger_kind,
        agent_provider: workflow.agent_provider,
        state: "queued",
        created_at: 5.minutes.ago,
        updated_at: 5.minutes.ago
      )
      solid_queue_run_job(root_run, claimed: true, worker_host: "chaos-live-worker-#{case_number}", live_process: true)
      trace << "successor_run=#{successor.id}:queued_inline"

      expectation(
        "queued inline successor owned by a live root RunJob",
        target: { workflow_id: workflow.id },
        forbidden_issues: %i[queued_run_without_queue_claim queued_run_stale_queue_claim],
        forbidden_actions: %i[reenqueue_run]
      )
    end

    def epic_workflow_conflict
      reset_shared_repository!
      epic = Factories.epic(user: shared_user, repository: shared_repository)
      keeper_job = Factories.job_record(
        user: shared_user,
        repository: shared_repository,
        epic: epic,
        issue_number: 40_000 + case_number,
        agent_provider: random_provider
      )
      conflict_job = Factories.job_record(
        user: shared_user,
        repository: shared_repository,
        epic: epic,
        issue_number: 41_000 + case_number,
        agent_provider: random_provider
      )
      keeper = active_workflow!(job: keeper_job, trigger_kind: "stack_rebase", step_kind: "stack_agent_rebase", age: 2.minutes)
      conflict_kind = random.rand(2).zero? ? "merge_train" : "initial"
      conflict_step = conflict_kind == "merge_train" ? "merge_train_build" : "implement"
      conflict = active_workflow!(job: conflict_job, trigger_kind: conflict_kind, step_kind: conflict_step, age: 1.minute)
      conflict.set_artifact!("merge_train_id", 900_000 + case_number) if conflict_kind == "merge_train"
      trace << "epic=#{epic.id}:workflow_conflict keeper=#{keeper.id}/#{keeper.trigger_kind} conflict=#{conflict.id}/#{conflict.trigger_kind}"

      expectation(
        "Epic-wide workflow conflict",
        target: {},
        expected_issue: :epic_workflow_conflict,
        expected_action: :cancel_epic_workflow_conflict,
        required_plans: [ [ :cancel_epic_workflow_conflict, conflict ] ]
      )
    end

    def queued_job_after_epic_workflow_conflict
      job, workflow, step, run = graph
      epic = Factories.epic(user: shared_user, repository: shared_repository)
      job.update!(epic: epic)
      workflow.update!(
        artifacts: {
          "cancelled_reason" => EpicWorkflowLock::BLOCK_REASON,
          "cancelled_details" => {
            "keeper_workflow_id" => 800_000 + case_number,
            "keeper_trigger_kind" => "stack_rebase"
          }
        }
      )
      workflow.update_columns(state: "cancelled", started_at: 20.minutes.ago, finished_at: 10.minutes.ago)
      step.update_columns(state: "cancelled", started_at: 20.minutes.ago, finished_at: 10.minutes.ago)
      run.update_columns(state: "cancelled", started_at: 20.minutes.ago, finished_at: 10.minutes.ago)
      job.update_columns(state: "queued")
      trace << "job=#{job.id}:queued_after_epic_conflict_cancel workflow=#{workflow.id}"

      expectation(
        "queued job after cleared Epic-wide workflow conflict",
        target: { job_id: job.id },
        expected_issue: :queued_job_after_epic_workflow_conflict,
        expected_action: :retry_job_after_epic_workflow_conflict,
        required_plans: [ [ :retry_job_after_epic_workflow_conflict, job ] ],
        forbidden_issues: %i[epic_workflow_conflict unambiguous_job_state_drift],
        forbidden_actions: %i[cancel_epic_workflow_conflict reconcile_job_state]
      )
    end

    def queued_job_after_cancelled_workflow
      job, workflow, step, run = graph
      workflow.update!(artifacts: { "main_broken" => true })
      workflow.update_columns(state: "cancelled", started_at: 20.minutes.ago, finished_at: 10.minutes.ago)
      step.update_columns(state: "cancelled", started_at: 20.minutes.ago, finished_at: 10.minutes.ago)
      run.update_columns(
        state: "cancelled",
        agent_outcome: "success",
        started_at: 20.minutes.ago,
        finished_at: 10.minutes.ago
      )
      job.update_columns(state: "queued")
      trace << "job=#{job.id}:queued_after_uncategorized_cancel workflow=#{workflow.id}"

      expectation(
        "queued job after uncategorized cancelled workflow",
        target: { job_id: job.id },
        expected_issue: :queued_job_after_cancelled_workflow,
        expected_action: :retry_job_after_cancelled_workflow,
        required_plans: [ [ :retry_job_after_cancelled_workflow, job ] ],
        forbidden_issues: %i[epic_workflow_conflict queued_job_after_epic_workflow_conflict unambiguous_job_state_drift],
        forbidden_actions: %i[cancel_epic_workflow_conflict retry_job_after_epic_workflow_conflict reconcile_job_state]
      )
    end

    def stale_auto_retry_workflow_with_queued_run
      job, source, step, run = graph
      fail_run!(source, step, run)
      job.update!(state: "implemented")
      successful = Workflows::Retry.instantiate(job: job, agent_provider: job.agent_provider)
      successful.update_columns(
        state: "succeeded",
        created_at: 4.minutes.ago,
        started_at: 4.minutes.ago,
        finished_at: 3.minutes.ago
      )
      attempt = AutoRetryAttempt.create!(
        job: job,
        workflow: source,
        run: run,
        agent_provider: job.agent_provider,
        failure_classification: "worker_died",
        retry_kind: "retry_workflow",
        attempt_number: 1,
        scheduled_at: 2.minutes.ago,
        performed_at: 2.minutes.ago
      )
      stale = Workflows::Retry.instantiate(
        job: job,
        artifacts: { "auto_retry_attempt_id" => attempt.id },
        agent_provider: job.agent_provider
      )
      stale.update_columns(created_at: 2.minutes.ago, updated_at: 2.minutes.ago)
      StepDispatcher.start_workflow(stale)
      stale_run = stale.first_step.runs.first
      stale_run.update_columns(created_at: old_active_age.ago, updated_at: old_active_age.ago)
      trace << "workflow=#{stale.id}:stale_auto_retry run=#{stale_run.id}:old_queued"

      expectation(
        "stale auto-retry workflow with queued run",
        target: { workflow_id: stale.id },
        expected_issue: :stale_auto_retry_workflow,
        expected_action: :cancel_stale_auto_retry_workflow,
        forbidden_issues: %i[queued_run_without_queue_claim],
        forbidden_actions: %i[reenqueue_run]
      )
    end

    def active_workflow!(job:, trigger_kind:, step_kind:, age:)
      workflow = Workflow.create!(job: job, trigger_kind: trigger_kind)
      step = Step.create!(workflow: workflow, kind: step_kind, position: 0)
      run = Run.create!(
        job: job,
        user: job.user,
        step: step,
        trigger_kind: trigger_kind,
        agent_provider: workflow.agent_provider,
        state: "running",
        started_at: age.ago,
        last_heartbeat_at: Time.current
      )
      workflow.update_columns(state: "running", started_at: age.ago, created_at: age.ago, updated_at: age.ago)
      step.update_columns(state: "running", started_at: age.ago, updated_at: age.ago)
      trace << "workflow=#{workflow.id}:active trigger=#{trigger_kind} step=#{step.kind} run=#{run.id}"
      workflow
    end

    def stale_auto_retry_after_branch_divergence_recovery
      job, source, step, run = graph
      branch = "syrus/issue-#{case_number}-#{job.id}"
      remote_sha = "remote-#{case_number}"
      local_sha = "local-#{case_number}"
      job.update_columns(
        state: "implemented",
        pr_number: 10_000 + case_number,
        branch_name: branch,
        mergeability_head_sha: remote_sha
      )
      source.update_columns(state: "failed", trigger_kind: "retry", finished_at: 5.minutes.ago)
      step.update_columns(kind: "pr_open", state: "failed", finished_at: 5.minutes.ago)
      run.update_columns(state: "failed", finished_at: 5.minutes.ago)
      source.set_artifact!("branch_divergence", {
        "branch" => branch,
        "remote_sha" => remote_sha,
        "local_sha" => local_sha
      })
      source.set_artifact!("branch_divergence_recovery", {
        "action" => "superseded_by_current_pr_branch",
        "at" => 4.minutes.ago.iso8601
      })
      RunFailureClassification.create!(
        run: run,
        classification: "branch_diverged",
        retryable: false,
        confidence: 0.95,
        reason: "chaos branch divergence",
        classified_at: 5.minutes.ago
      )
      attempt = AutoRetryAttempt.create!(
        job: job,
        workflow: source,
        run: run,
        agent_provider: job.agent_provider,
        failure_classification: "branch_diverged",
        retry_kind: "retry_workflow",
        attempt_number: 1,
        scheduled_at: 2.minutes.ago,
        performed_at: 2.minutes.ago
      )
      stale = Workflows::Retry.instantiate(
        job: job,
        artifacts: { "auto_retry_attempt_id" => attempt.id },
        agent_provider: job.agent_provider
      )
      stale.update_columns(created_at: 2.minutes.ago, updated_at: 2.minutes.ago)
      StepDispatcher.start_workflow(stale)
      stale_run = stale.first_step.runs.first
      stale_run.update_columns(created_at: old_active_age.ago, updated_at: old_active_age.ago)
      trace << "workflow=#{stale.id}:stale_auto_retry_after_branch_recovery run=#{stale_run.id}:old_queued"

      expectation(
        "stale auto-retry after branch divergence recovery",
        target: { workflow_id: stale.id },
        expected_issue: :stale_auto_retry_workflow,
        expected_action: :cancel_stale_auto_retry_workflow,
        forbidden_issues: %i[queued_run_without_queue_claim nonretryable_semantic_git_failure retryable_run_failure],
        forbidden_actions: %i[reenqueue_run operator_review_nonretryable_failure retry_workflow]
      )
    end

    def stale_branch_diverged_workflow
      job, workflow, step, run = graph
      branch = "syrus/issue-#{case_number}-#{job.id}"
      remote_sha = "remote-#{case_number}"
      local_sha = "local-#{case_number}"
      job.update_columns(
        state: "queued",
        pr_number: 10_000 + case_number,
        branch_name: branch,
        mergeability_head_sha: remote_sha
      )
      workflow.update_columns(state: "failed", trigger_kind: "retry", finished_at: 5.minutes.ago)
      step.update_columns(kind: "pr_open", state: "failed", finished_at: 5.minutes.ago)
      run.update_columns(state: "failed", finished_at: 5.minutes.ago)
      workflow.set_artifact!("branch_divergence", {
        "branch" => branch,
        "remote_sha" => remote_sha,
        "local_sha" => local_sha
      })
      RunFailureClassification.create!(
        run: run,
        classification: "branch_diverged",
        retryable: false,
        confidence: 0.95,
        reason: "chaos branch divergence",
        classified_at: 5.minutes.ago
      )
      trace << "workflow=#{workflow.id}:stale_branch_diverged remote=#{remote_sha} local=#{local_sha}"

      expectation(
        "stale branch-diverged workflow",
        target: { workflow_id: workflow.id },
        expected_issue: :stale_branch_diverged_workflow,
        expected_action: :discard_superseded_branch_output,
        forbidden_issues: %i[nonretryable_semantic_git_failure retryable_run_failure],
        forbidden_actions: %i[operator_review_nonretryable_failure retry_workflow]
      )
    end

    def recovered_branch_diverged_failed_job
      job, workflow, step, run = graph
      branch = "syrus/issue-#{case_number}-#{job.id}"
      remote_sha = "remote-#{case_number}"
      local_sha = "local-#{case_number}"
      job.update_columns(
        state: "failed",
        pr_number: 10_000 + case_number,
        branch_name: branch,
        mergeability_head_sha: remote_sha
      )
      workflow.update_columns(state: "failed", trigger_kind: "retry", finished_at: 5.minutes.ago)
      step.update_columns(kind: "pr_open", state: "failed", finished_at: 5.minutes.ago)
      run.update_columns(state: "failed", finished_at: 5.minutes.ago)
      workflow.set_artifact!("branch_divergence", {
        "branch" => branch,
        "remote_sha" => remote_sha,
        "local_sha" => local_sha
      })
      workflow.set_artifact!("branch_divergence_recovery", {
        "action" => "superseded_by_current_pr_branch",
        "at" => 4.minutes.ago.iso8601
      })
      RunFailureClassification.create!(
        run: run,
        classification: "branch_diverged",
        retryable: false,
        confidence: 0.95,
        reason: "chaos branch divergence",
        classified_at: 5.minutes.ago
      )
      trace << "job=#{job.id}:failed_recovered_branch_divergence remote=#{remote_sha} local=#{local_sha}"

      expectation(
        "recovered branch-diverged failed job",
        target: { job_id: job.id },
        expected_issue: :unambiguous_job_state_drift,
        expected_action: :reconcile_job_state,
        forbidden_issues: %i[nonretryable_semantic_git_failure retryable_run_failure branch_diverged_pr_open],
        forbidden_actions: %i[operator_review_nonretryable_failure retry_workflow]
      )
    end

    def running_step_with_failed_terminal_run
      _job, workflow, step, _run = graph
      run = failed_terminal_run_on_running_step!(workflow, step)

      expectation(
        "running step with failed terminal run",
        target: { workflow_id: workflow.id },
        expected_issue: :running_step_with_terminal_runs,
        expected_action: :reconcile_step_from_terminal_run,
        required_plans: [ [ :reconcile_step_from_terminal_run, step ] ],
        forbidden_issues: %i[retryable_run_failure nonretryable_semantic_git_failure],
        forbidden_plans: [ [ :retry_failed_step, run ], [ :retry_workflow, workflow ] ]
      )
    end

    def queued_step_without_run_after_succeeded_step
      _job, workflow, step, _run = graph
      queued_step = queued_successor_without_run!(workflow, step)

      expectation(
        "queued step without run after succeeded predecessor",
        target: { workflow_id: workflow.id },
        expected_issue: :queued_step_without_run,
        expected_action: :resume_queued_step,
        required_plans: [ [ :resume_queued_step, queued_step ] ],
        forbidden_actions: %i[reenqueue_run start_workflow]
      )
    end

    def running_step_with_succeeded_terminal_run
      _job, workflow, step, _run = graph
      run = succeeded_terminal_run_on_running_step!(workflow, step)

      expectation(
        "running step with succeeded terminal run",
        target: { workflow_id: workflow.id },
        expected_issue: :running_step_with_terminal_runs,
        expected_action: :reconcile_step_from_terminal_run,
        required_plans: [ [ :reconcile_step_from_terminal_run, step ] ],
        forbidden_issues: %i[retryable_run_failure nonretryable_semantic_git_failure],
        forbidden_plans: [ [ :retry_failed_step, run ], [ :retry_workflow, workflow ] ]
      )
    end

    def closed_job_with_active_workflow
      job, workflow, step, run = graph
      running_run!(workflow, step, run, heartbeat_age: stale_heartbeat_age)
      job.update_columns(state: "closed", finished_at: 10.minutes.ago, closure_reason: "operator_cancelled")

      expectation(
        "closed job with active workflow",
        target: { workflow_id: workflow.id },
        expected_issue: :closed_job_active_workflow,
        expected_action: :cancel_workflow_for_closed_job,
        required_plans: [ [ :cancel_workflow_for_closed_job, workflow ] ],
        forbidden_issues: %i[running_run_without_live_worker_evidence queued_run_without_queue_claim retryable_run_failure],
        forbidden_actions: %i[reenqueue_run mark_worker_died mark_worker_died_and_retry_failed_step mark_worker_died_and_retry_workflow]
      )
    end

    def stale_running_run_without_worker_evidence
      _job, workflow, step, run = graph
      running_run!(workflow, step, run, heartbeat_age: stale_heartbeat_age)

      expectation(
        "stale running run without worker evidence",
        target: { run_id: run.id },
        expected_issue: :running_run_without_live_worker_evidence,
        expected_action: :mark_worker_died_and_retry_failed_step
      )
    end

    def fresh_running_run
      _job, workflow, step, run = graph
      running_run!(workflow, step, run, heartbeat_age: random.rand(10..50).seconds)

      expectation(
        "fresh running run",
        target: { run_id: run.id },
        forbidden_issues: %i[running_run_without_live_worker_evidence],
        forbidden_actions: %i[mark_worker_died mark_worker_died_and_retry_failed_step mark_worker_died_and_retry_workflow]
      )
    end

    def missing_local_workspace
      _job, workflow, step, run = graph
      running_run!(workflow, step, run, heartbeat_age: random.rand(10..50).seconds)
      missing_workspace!(workflow)

      expectation(
        "missing local workspace",
        target: { workflow_id: workflow.id },
        expected_issue: :workspace_missing,
        expected_action: :operator_review_missing_workspace
      )
    end

    def missing_remote_live_worker_workspace
      _job, workflow, step, run = graph
      worker_host = "chaos-remote-live-worker-#{case_number}"
      live_worker_hosts << worker_host
      running_run!(workflow, step, run, heartbeat_age: random.rand(10..50).seconds)
      workflow.update_columns(worker_hostname: worker_host)
      missing_workspace!(workflow)

      expectation(
        "missing workspace on another live worker",
        target: { workflow_id: workflow.id },
        forbidden_issues: %i[workspace_missing],
        forbidden_actions: %i[operator_review_missing_workspace]
      )
    end

    def stale_main_broken_artifact_after_recovery
      job, workflow, step, run = graph
      fail_run!(workflow, step, run)
      job.repository.update!(main_branch_health_enabled: true, ci_health: "healthy", grader_health: "healthy", landing_paused: false)
      workflow.update!(artifacts: { "main_broken" => true })
      trace << "main_health=recovered stale_artifact=true"

      expectation(
        "stale main-broken artifact after recovery",
        target: { workflow_id: workflow.id },
        forbidden_issues: %i[main_branch_broken main_health_start_block],
        forbidden_actions: %i[wait_for_main_recovery wait_for_main_health]
      )
    end

    def active_main_health_start_block
      job, workflow, _step, run = graph
      remove_first_run!(workflow, run)
      job.repository.update!(main_branch_health_enabled: true, ci_health: "broken", grader_health: "broken", landing_paused: true)
      workflow.update!(
        artifacts: {
          "start_blocked_reason" => StepDispatcher::MAIN_HEALTH_BLOCK_REASON,
          "start_blocked_next_check_at" => 5.minutes.from_now.iso8601
        }
      )
      trace << "main_health=broken"

      expectation(
        "active main-health start block",
        target: { workflow_id: workflow.id },
        expected_issue: :main_health_start_block,
        expected_action: :wait_for_main_health
      )
    end

    def recovered_main_health_start_block
      job, workflow, _step, run = graph
      remove_first_run!(workflow, run)
      job.repository.update!(main_branch_health_enabled: true, ci_health: "healthy", grader_health: "healthy", landing_paused: false)
      workflow.update!(
        artifacts: {
          "start_blocked_reason" => StepDispatcher::MAIN_HEALTH_BLOCK_REASON,
          "start_blocked_next_check_at" => 5.minutes.from_now.iso8601
        }
      )
      trace << "main_health=recovered"

      expectation(
        "recovered main-health start block",
        target: { workflow_id: workflow.id },
        expected_issue: :queued_workflow_without_first_run,
        expected_action: :start_workflow,
        forbidden_issues: %i[main_health_start_block],
        forbidden_actions: %i[wait_for_main_health]
      )
    end

    def expired_dependency_start_block
      _job, workflow, _step, run = graph
      remove_first_run!(workflow, run)
      workflow.update!(
        artifacts: {
          "start_blocked_reason" => StepDispatcher::STACK_BLOCK_REASON,
          "start_blocked_next_check_at" => 1.minute.ago.iso8601
        }
      )
      trace << "dependency_start_block=expired"

      expectation(
        "expired dependency start block",
        target: { workflow_id: workflow.id },
        expected_issue: :queued_workflow_without_first_run,
        expected_action: :start_workflow,
        forbidden_issues: %i[dependency_stack_start_block],
        forbidden_actions: %i[wait_for_dependency_or_stack_readiness]
      )
    end

    def orphaned_landing_job
      job, workflow, step, run = graph
      workflow.update_columns(state: "succeeded", finished_at: 2.minutes.ago)
      step.update_columns(state: "succeeded", finished_at: 2.minutes.ago)
      run.update_columns(state: "succeeded", finished_at: 2.minutes.ago)
      job.update_columns(state: "landing", approved_at: 3.minutes.ago, approved_via: "operator")
      trace << "job=#{job.id}:orphaned_landing_slot"

      expectation(
        "orphaned landing job",
        target: { job_id: job.id },
        expected_issue: :landing_job_without_active_workflow,
        expected_action: :defer_orphaned_landing_job
      )
    end

    def running_workflow_without_active_descendants
      _job, workflow, _step, run = graph
      workflow.update_columns(state: "running", started_at: 6.minutes.ago)
      workflow.steps.update_all(state: "succeeded", finished_at: 4.minutes.ago)
      run.update_columns(state: "succeeded", finished_at: 4.minutes.ago)
      trace << "workflow=#{workflow.id}:running_without_active_descendants"

      expectation(
        "running workflow without active descendants",
        target: { workflow_id: workflow.id },
        expected_issue: :running_workflow_without_active_descendants,
        expected_action: :finish_workflow_from_terminal_descendants
      )
    end

    def running_workflow_with_failed_step
      _job, workflow, step, run = graph
      next_step = step.next_step || workflow.steps.where("position > ?", step.position).order(:position).first
      next_step ||= Step.create!(workflow: workflow, kind: "pr_open", position: step.position + 1)
      workflow.update_columns(state: "running", started_at: 6.minutes.ago)
      step.update_columns(kind: "test_plan", state: "failed", finished_at: 4.minutes.ago, next_step_id: next_step.id)
      next_step.update_columns(state: "queued", started_at: nil, finished_at: nil)
      run.update_columns(state: "failed", agent_outcome: "error", finished_at: 4.minutes.ago)
      trace << "workflow=#{workflow.id}:running_with_failed_step=#{step.id}"

      expectation(
        "running workflow with failed step",
        target: { workflow_id: workflow.id },
        expected_issue: :running_workflow_with_failed_step,
        expected_action: :fail_workflow_from_failed_step,
        forbidden_issues: %i[running_workflow_without_active_descendants]
      )
    end

    def terminal_workflow_with_active_descendants
      _job, workflow, step, run = graph
      workflow.update_columns(state: "succeeded", finished_at: 5.minutes.ago, cleaned_up_at: nil)
      step.update_columns(state: "running", started_at: 6.minutes.ago)
      run.update_columns(state: "running", started_at: 6.minutes.ago, last_heartbeat_at: 30.seconds.ago)
      trace << "workflow=#{workflow.id}:terminal_with_active_descendants"

      expectation(
        "terminal workflow with active descendants",
        target: { workflow_id: workflow.id },
        expected_issue: :cleanup_blocked_by_active_descendants,
        expected_action: :operator_review_active_descendants
      )
    end

    def fail_run!(workflow, step, run)
      workflow.update_columns(state: "failed", finished_at: 5.minutes.ago, cleaned_up_at: nil)
      step.update_columns(kind: "grader", state: "failed", finished_at: 5.minutes.ago)
      run.update_columns(state: "failed", finished_at: 5.minutes.ago)
      RunFailureClassification.create!(
        run: run,
        classification: "timeout",
        retryable: true,
        confidence: 0.9,
        reason: "chaos retryable failure",
        classified_at: 5.minutes.ago
      )
      trace << "run=#{run.id}:failed"
    end

    def expectation(label, target:, expected_issue: nil, expected_action: nil, expected_issues: [], expected_actions: [], forbidden_issues: [], forbidden_actions: [],
                    required_plans: [], forbidden_plans: [], forbidden_workflow_issues: [], stale_auto_retry_workflow_ids: [])
      CaseExpectation.new(
        label: label,
        target: target,
        expected_issue: expected_issue,
        expected_action: expected_action,
        expected_issues: expected_issues,
        expected_actions: expected_actions,
        forbidden_issues: forbidden_issues,
        forbidden_actions: forbidden_actions,
        required_plans: required_plans,
        forbidden_plans: forbidden_plans,
        forbidden_workflow_issues: forbidden_workflow_issues,
        stale_auto_retry_workflow_ids: stale_auto_retry_workflow_ids,
        trace: trace.dup
      )
    end
  end

  around do |example|
    clear_enqueued_jobs
    clear_performed_jobs
    example.run
    clear_enqueued_jobs
    clear_performed_jobs
  end

  before do
    ensure_solid_queue_test_tables!
    clear_solid_queue_test_tables!
    allow(ProviderCircuitBreaker).to receive(:open_circuits).and_return([])
    allow(InstanceVersion).to receive(:worst_data_root).and_return(nil)
    allow(File).to receive(:directory?).and_return(true)
  end

  after do
    clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
  end

  def chaos_case_count
    Integer(ENV.fetch("WORK_ENGINE_CHAOS_CASES", "5"))
  end

  def issue_kinds(result)
    result.issues.map(&:kind)
  end

  def plan_actions(result)
    result.repair_plans.map(&:action)
  end

  def plan_targets(result)
    result.repair_plans.map { |plan| [ plan.action, plan.target_type, plan.target_id ] }
  end

  def issue_affects_workflow?(issue, workflow_id)
    Array(issue.affected_ids["workflow_ids"] || issue.affected_ids[:workflow_ids]).include?(workflow_id)
  end

  def assert_chaos_case!(expectation)
    result = WorkEngine::Reconciler.call(source: "reconciler_chaos_spec", **expectation.target)
    repeat = WorkEngine::Reconciler.call(source: "reconciler_chaos_spec_repeat", **expectation.target)
    trace = expectation.trace.join("\n")

    aggregate_failures "#{expectation.label}\n#{trace}" do
      if expectation.expected_issue
        expect(issue_kinds(result)).to include(expectation.expected_issue), "expected issue #{expectation.expected_issue}; got #{issue_kinds(result).inspect}\n#{trace}"
      end

      expectation.expected_issues.each do |kind|
        expect(issue_kinds(result)).to include(kind), "expected issue #{kind}; got #{issue_kinds(result).inspect}\n#{trace}"
      end

      if expectation.expected_action
        expect(plan_actions(result)).to include(expectation.expected_action), "expected action #{expectation.expected_action}; got #{plan_actions(result).inspect}\n#{trace}"
      end

      expectation.expected_actions.each do |action|
        expect(plan_actions(result)).to include(action), "expected action #{action}; got #{plan_actions(result).inspect}\n#{trace}"
      end

      expectation.forbidden_issues.each do |kind|
        expect(issue_kinds(result)).not_to include(kind), "forbidden issue #{kind}; got #{issue_kinds(result).inspect}\n#{trace}"
      end

      expectation.forbidden_actions.each do |action|
        expect(plan_actions(result)).not_to include(action), "forbidden action #{action}; got #{plan_actions(result).inspect}\n#{trace}"
      end

      expectation.required_plans.each do |action, target_type, target_id|
        expect(plan_targets(result)).to include([ action, target_type, target_id ]),
          "expected plan #{action} for #{target_type}##{target_id}; got #{plan_targets(result).inspect}\n#{trace}"
      end

      expectation.forbidden_plans.each do |action, target_type, target_id|
        expect(plan_targets(result)).not_to include([ action, target_type, target_id ]),
          "forbidden plan #{action} for #{target_type}##{target_id}; got #{plan_targets(result).inspect}\n#{trace}"
      end

      expectation.forbidden_workflow_issues.each do |kind, workflow_id|
        matching = result.issues.select { |issue| issue.kind == kind && issue_affects_workflow?(issue, workflow_id) }
        expect(matching).to be_empty,
          "forbidden issue #{kind} for Workflow##{workflow_id}; got #{matching.map(&:as_json).inspect}\n#{trace}"
      end

      expectation.stale_auto_retry_workflow_ids.each do |workflow_id|
        runs = Workflow.find(workflow_id).runs.pluck(:id)
        expect(plan_targets(result)).to include([ "cancel_stale_auto_retry_workflow", "Workflow", workflow_id ]),
          "expected stale auto-retry cancellation for Workflow##{workflow_id}; got #{plan_targets(result).inspect}\n#{trace}"
        runs.each do |run_id|
          expect(plan_targets(result)).not_to include([ "reenqueue_run", "Run", run_id ]),
            "stale auto-retry Workflow##{workflow_id} Run##{run_id} must not be re-enqueued; got #{plan_targets(result).inspect}\n#{trace}"
        end
      end

      expect(issue_kinds(repeat)).to eq(issue_kinds(result)), "reconciler issue set was not stable across repeated reads\n#{trace}"
      expect(plan_actions(repeat)).to eq(plan_actions(result)), "reconciler plan set was not stable across repeated reads\n#{trace}"
      expect(plan_targets(result))
        .to eq(plan_targets(result).uniq),
          "duplicate repair plans emitted\n#{trace}"

      result.repair_plans.each do |plan|
        matching_issues = result.issues.select { |candidate| candidate.kind == plan.issue_kind }
        expect(matching_issues).to be_present, "plan #{plan.action} has no matching issue\n#{trace}"
        expect(plan.auto_executable).to be(false) unless matching_issues.any?(&:safe_to_auto_repair)
      end
    end
  end

  it "reconciles seeded random worker, queue, workspace, and main-health states without slow waits" do
    seed = Integer(ENV.fetch("WORK_ENGINE_CHAOS_SEED", Random.new_seed))
    simulation = ReconcilerChaosSimulation.new(seed: seed, spec_context: self)
    allow(InstanceVersion).to receive(:worker_live?) { |hostname| simulation.live_worker?(hostname) }

    chaos_case_count.times do
      expectation = simulation.next_case
      assert_chaos_case!(expectation)
    end
  end

  it "covers an empty graph and known interaction precedence cases" do
    seed = Integer(ENV.fetch("WORK_ENGINE_CHAOS_SEED", Random.new_seed))
    simulation = ReconcilerChaosSimulation.new(seed: seed, spec_context: self)
    allow(InstanceVersion).to receive(:worker_live?) { |hostname| simulation.live_worker?(hostname) }

    assert_chaos_case!(simulation.empty_topology_case)
    assert_chaos_case!(simulation.send(:stale_auto_retry_workflow_with_queued_run))
    assert_chaos_case!(simulation.send(:stale_auto_retry_after_branch_divergence_recovery))
    assert_chaos_case!(simulation.send(:stale_branch_diverged_workflow))
    assert_chaos_case!(simulation.send(:recovered_branch_diverged_failed_job))
    assert_chaos_case!(simulation.send(:queued_job_after_epic_workflow_conflict))
    assert_chaos_case!(simulation.send(:queued_job_after_cancelled_workflow))
    assert_chaos_case!(simulation.send(:running_step_with_failed_terminal_run))
    assert_chaos_case!(simulation.send(:running_step_with_succeeded_terminal_run))
    assert_chaos_case!(simulation.send(:running_workflow_with_failed_step))
    assert_chaos_case!(simulation.send(:closed_job_with_active_workflow))
  end

  it "reconciles one random degradation on a fully materialized random workflow topology" do
    seed = Integer(ENV.fetch("WORK_ENGINE_CHAOS_SEED", Random.new_seed))
    simulation = ReconcilerChaosSimulation.new(seed: seed, spec_context: self)
    allow(InstanceVersion).to receive(:worker_live?) { |hostname| simulation.live_worker?(hostname) }

    chaos_case_count.times do
      expectation = simulation.next_topology_case
      assert_chaos_case!(expectation)
    end
  end

  it "covers every registered workflow template and every registered step kind" do
    AppSetting.current.update!(adversarial_review_rounds: 1)
    allow(Feature).to receive(:visual_review_enabled?).and_return(true)
    user = Factories.user
    repository = Factories.repository(user: user)
    template_classes = Workflow::TriggerKind::ENTRIES.map(&:template_class).uniq
    static_step_kinds = Set.new

    Workflow::TriggerKind::ENTRIES.each do |entry|
      expect(Workflows.for(trigger_kind: entry.kind)).to eq(entry.template_class)
    end

    template_classes.each_with_index do |template, index|
      job = Factories.job_record(
        user: user,
        repository: repository,
        issue_number: 20_000 + index,
        state: "queued"
      )
      workflow = template.instantiate(job: job)
      expect(workflow.steps).to be_present
      static_step_kinds.merge(serialized_template_step_kinds(workflow.chain_template))
    end

    missing_from_templates = Step::Kind.values - static_step_kinds.to_a
    expect(missing_from_templates).to contain_exactly("apply_suggestions", "grade", "grader", "preflight_grader")

    job = Factories.job_record(user: user, repository: repository, issue_number: 21_000, state: "queued")
    workflow = Workflow.create!(job: job, trigger_kind: "manual", agent_provider: job.agent_provider)
    runs_by_kind = {}
    Step::Kind.values.each_with_index do |kind, index|
      step = Step.create!(workflow: workflow, kind: kind, position: index, iteration: 1)
      run = step.runs.create!(
        job: job,
        user: job.user,
        trigger_kind: workflow.trigger_kind,
        agent_provider: workflow.agent_provider,
        state: "queued",
        created_at: (WorkEngine::Reconciler::ORPHAN_RUN_GRACE_PERIOD + 2.minutes).ago,
        updated_at: (WorkEngine::Reconciler::ORPHAN_RUN_GRACE_PERIOD + 2.minutes).ago
      )
      runs_by_kind[kind] = run
    end
    workflow.update_columns(state: "running", started_at: 10.minutes.ago)

    result = WorkEngine::Reconciler.call(source: "reconciler_chaos_step_kind_matrix", workflow_id: workflow.id)
    Step::Kind.values.each do |kind|
      run = runs_by_kind.fetch(kind)
      expect(plan_targets(result)).to include([ "reenqueue_run", "Run", run.id ]), "missing reenqueue coverage for step kind #{kind}"
    end
  end

  it "covers retry-until grade-loop topology through iteration 3 and the third grader" do
    workflow_class = Class.new(Workflows::Base) do
      steps Workflows::RetryUntil.new(
              max_iterations: 3,
              repair: [ :implement ],
              check: [ :grader_fanout, :grader_collect ]
            ),
            :summarize

      def self.trigger_kind = "initial"
    end

    job = Factories.job_record(state: "queued")
    workflow = workflow_class.instantiate(job: job)
    workflow.update_columns(state: "running", started_at: 10.minutes.ago)

    insert_grader_steps!(workflow, iteration: 1, count: 3)
    StepDispatcher.fail_from(workflow.steps.find_by!(kind: "grader_collect", iteration: 1))
    insert_grader_steps!(workflow, iteration: 2, count: 3)
    StepDispatcher.fail_from(workflow.steps.find_by!(kind: "grader_collect", iteration: 2))
    insert_grader_steps!(workflow, iteration: 3, count: 3)

    third_grader = workflow.steps.where(kind: "grader", iteration: 3).order(:position).third
    run = third_grader.runs.create!(
      job: job,
      user: job.user,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider,
      state: "queued",
      created_at: (WorkEngine::Reconciler::ORPHAN_RUN_GRACE_PERIOD + 2.minutes).ago,
      updated_at: (WorkEngine::Reconciler::ORPHAN_RUN_GRACE_PERIOD + 2.minutes).ago
    )

    expect(workflow.steps.where(kind: "grader_collect").pluck(:iteration)).to eq([ 1, 2, 3 ])
    expect(workflow.steps.where(kind: "grader", iteration: 3).count).to eq(3)
    expect(third_grader.loop_id).to eq(workflow.steps.find_by!(kind: "grader_collect", iteration: 3).loop_id)

    result = WorkEngine::Reconciler.call(source: "reconciler_chaos_grade_loop_topology", workflow_id: workflow.id)
    expect(plan_targets(result)).to include([ "reenqueue_run", "Run", run.id ])
  end

  def serialized_template_step_kinds(nodes)
    Array(nodes).flat_map do |node|
      case node["type"]
      when "step"
        node.fetch("kind")
      when "loop"
        Array(node.fetch("steps"))
      when "retry_until"
        Array(node.fetch("repair")) + Array(node.fetch("check"))
      when "try"
        [ node.fetch("step") ] + node.fetch("on_failure", {}).values.flat_map { |branch| serialized_template_step_kinds(branch) }
      else
        raise "unknown workflow template node: #{node.inspect}"
      end
    end.uniq
  end

  def insert_grader_steps!(workflow, iteration:, count:)
    fanout = workflow.steps.find_by!(kind: "grader_fanout", iteration: iteration)
    collect = workflow.steps.find_by!(kind: "grader_collect", iteration: iteration)
    return if workflow.steps.where(kind: "grader", iteration: iteration, loop_id: fanout.loop_id).exists?

    insertion_position = fanout.position + 1
    workflow.steps.where("position >= ?", insertion_position).update_all([ "position = position + ?", count ])

    graders = count.times.map do |index|
      Step.create!(
        workflow: workflow,
        kind: "grader",
        position: insertion_position + index,
        iteration: iteration,
        loop_id: fanout.loop_id,
        details: { "name" => "grader-#{iteration}-#{index + 1}", "required" => true }
      )
    end

    ([ fanout ] + graders + [ collect ]).each_cons(2) do |step, next_step|
      step.update!(next_step_id: next_step.id)
    end
  end
end
