require "rails_helper"
require "tmpdir"

# The runner-side pieces the fuzzer builds on: per-tick invariant assertions,
# tick-scheduled events, and the perturbation actions, each exercised on a
# real (rolled back) simulated world.
RSpec.describe WorkEngine::Simulation::Runner do
  self.use_transactional_tests = false

  around do |example|
    Dir.mktmpdir("simulator_perturbations") do |dir|
      @dir = Pathname(dir)
      Rails.logger.silence do
        PerformanceLogging.suppress do
          WorkEngine::Simulation::ScenarioExecution.wrap { example.run }
        end
      end
    end
  end

  before do
    stub_no_workflow_judges
    [ Workflow, Step, Run ].each { |model| allow_any_instance_of(model).to receive(:broadcast_job_progress_event) }
    allow(App::ProviderAvailability).to receive(:broadcast_changed)
  end

  def run(yaml, max_ticks: 60)
    path = @dir.join("scenario-#{SecureRandom.hex(4)}.yml")
    path.write(yaml)
    WorkEngine::Simulation::ScenarioRunner.call(path: path, max_ticks: max_ticks)
  end

  SINGLE_JOB = <<~YAML
    name: perturbed single job
    repository:
      owner: simulation
      name: perturbed-single-job
    jobs:
      job:
        title: Single job
        state: queued
        workflow:
          template: true
          kind: initial
    outcomes:
      default: success
    success_states:
      job:
        - implemented
  YAML

  # A failed dependency with a dependent still waiting: the shape the
  # failed_blockers invariant exists for. Nothing retries the parent, so
  # the world goes quiet with the dependent blocked.
  FAILED_BLOCKER = <<~YAML
    name: failed blocker
    runner:
      auto_retry_failed_jobs: false
    repository:
      owner: simulation
      name: failed-blocker
    jobs:
      parent:
        title: Parent job
        state: queued
        workflow:
          template: true
          kind: initial
      child:
        title: Child job
        state: queued
        depends_on:
          - parent
        workflow:
          template: true
          kind: initial
    outcomes:
      default: success
      steps:
        parent:implement:
          status: failure
          error_message: deterministic compile error
    success_states:
      parent: [implemented]
      child: [implemented]
  YAML

  describe "invariant assertions" do
    it "fails a scenario whose quiescent end state violates an invariant" do
      result = run(FAILED_BLOCKER)

      expect(result.status).to eq("violated")
      expect(result.invariant_violations).to include(a_string_including("invariant failed_blockers"))
      expect(result.stuck_reasons.first).to eq("scenario otherwise ended stuck")
    end

    it "lets a scenario expect the violation it models" do
      result = run(FAILED_BLOCKER + <<~YAML)
        invariants:
          expected:
            - invariant: failed_blockers
              job: parent
              required: true
              reason: the scenario models a failed dependency holding its dependent
      YAML

      expect(result.status).to eq("stuck")
      expect(result.invariant_violations).to be_empty
    end

    # The checker raises in the suite, but a raise inside the engine is often
    # rescued and logged; the runner records instead, so an inversion fails
    # the scenario even where the code under test swallows the error.
    it "fails a scenario that takes row locks out of order, even when the inversion is rescued" do
      allow(JobManualPause).to receive(:pause!).and_wrap_original do |original, *args, **kwargs|
        begin
          Syrus::LockOrder::Checker.send(:report, Syrus::LockOrder::Violation.new(held: "WorkUnit", taking: "Job", site: "spec", held_site: "spec"))
        rescue Syrus::LockOrder::Error
          nil
        end
        original.call(*args, **kwargs)
      end

      result = run(SINGLE_JOB + <<~YAML)
        events:
          - name: operator pauses
            once: true
            when: { tick: 2 }
            do: { pause_work: job }
          - name: operator unpauses
            once: true
            when: { tick: 4 }
            do: { unpause_work: job }
      YAML

      expect(result.status).to eq("violated")
      expect(result.invariant_violations).to include("invariant lock_order: took Job at spec while holding WorkUnit from spec")
      expect(Syrus::LockOrder::Checker.mode).to eq(:raise)
    end

    it "can be switched off by the caller" do
      path = @dir.join("blocker.yml")
      path.write(FAILED_BLOCKER)

      expect(WorkEngine::Simulation::ScenarioRunner.call(path: path, max_ticks: 60, invariants: false).status).to eq("stuck")
    end
  end

  describe "perturbation events" do
    it "injects a worker death into the next run of a Job at a scheduled tick" do
      result = run(SINGLE_JOB + <<~YAML)
        events:
          - name: worker dies
            fuzz: worker_died
            once: true
            when: { tick: { at_least: 1 } }
            do:
              inject_outcome: { job: job, step: implement, outcome: worker_died }
      YAML

      expect(result.status).to eq("success")
      expect(result.events).to include(a_string_matching(/tick 1: event worker dies/))
      expect(result.events).to include(a_string_matching(/implement -> worker_died/))
    end

    it "pauses and unpauses a Job through the operator path" do
      result = run(SINGLE_JOB + <<~YAML)
        events:
          - name: operator pauses
            once: true
            when: { tick: 2 }
            do: { pause_work: job }
          - name: operator unpauses
            once: true
            when: { tick: 6 }
            do: { unpause_work: job }
      YAML

      expect(result.events).to include("operator paused #{result.final_states.keys.first}", "operator unpaused #{result.final_states.keys.first}")
      expect(result.status).to eq("success")
    end

    it "does not call a quiet world stuck while a tick-scheduled event is still due" do
      result = run(SINGLE_JOB + <<~YAML)
        success_states:
          job: [closed]
        events:
          - name: late close
            once: true
            when: { tick: { at_least: 40 } }
            do: { close: job }
      YAML

      expect(result.status).to eq("success")
      expect(result.events).to include(a_string_matching(/tick 40: event late close/))
    end

    # Regression: the runner failed a Step a second time after Run#fail! had
    # already propagated, undoing the dispatcher's provider-backoff reopen and
    # hard-failing a Workflow production keeps running.
    it "reruns a transiently failed step after its backoff instead of failing the workflow" do
      result = run(<<~YAML)
        name: transient prepare failure
        runner:
          auto_retry_failed_jobs: false
        repository:
          owner: simulation
          name: transient-prepare-failure
        jobs:
          job:
            title: Transient prepare failure
            state: queued
            workflow:
              template: true
              kind: initial
        outcomes:
          default: success
          steps:
            job:prepare:
              - status: failure
                failure_code: rate_limited
                error_message: simulated transient rate_limited
              - success
        success_states:
          job: [implemented]
      YAML

      expect(result.status).to eq("success")
      expect(result.events).to include(a_string_matching(/phase admission ran for workflow/))
      expect(result.events.grep(/retry .* via/)).to be_empty
    end

    # Regression: the runner failed a Step that propagation had left running
    # for its scheduled in-place rerun, so the rerun later raised on a Step
    # that was no longer failed or running.
    it "lets a worker death under prepare rerun in place" do
      result = run(SINGLE_JOB + <<~YAML)
        events:
          - name: worker dies under prepare
            once: true
            when: { tick: 0 }
            do:
              inject_outcome: { job: job, step: prepare, outcome: worker_died }
      YAML

      expect(result.status).to eq("success")
      expect(result.events).to include(a_string_matching(/auto retry 1 failed_step -> started/))
    end

    it "answers the landing queue's mergeability poll so an approved Job without evidence still lands" do
      result = run(<<~YAML)
        name: approved without mergeability evidence
        repository:
          owner: simulation
          name: approved-without-mergeability-evidence
          auto_merge_enabled: true
        jobs:
          job:
            title: Approved before any mergeability poll
            state: approved
            branch_name: syrus/direct-approved-no-evidence
            pr_number: 7101
            pr_checks_state: passing
            approved_at: "2026-09-15 08:00:00"
        outcomes:
          default: success
        success_states:
          job: [closed]
      YAML

      expect(result.status).to eq("success")
      expect(result.events).to include(a_string_matching(/mergeability poll answered clean/))
    end

    it "treats an approval the Job's state refuses as no action at all" do
      result = run(Rails.root.join("spec/fixtures/work_engine_simulations/stalled_intake_reclassifies.yml").read + <<~YAML)
        events:
          - name: refused approval
            once: true
            when: { tick: 0 }
            do: { approve: job }
      YAML

      expect(result.status).to eq("success")
    end

    it "records an inapplicable injected event instead of aborting the scenario" do
      result = run(SINGLE_JOB + <<~YAML)
        events:
          - name: impossible storage loss
            fuzz: lose_storage
            once: true
            when: { tick: 1 }
            do: { lose_storage: { job: job } }
      YAML

      expect(result.status).to eq("success")
      expect(result.events).to include(a_string_matching(/fuzz event impossible storage loss inapplicable/))
    end
  end
end
