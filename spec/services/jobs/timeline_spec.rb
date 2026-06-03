require "rails_helper"

RSpec.describe Jobs::Timeline do
  let(:job) { Factories.job }

  def titles_of(events) = events.map(&:title)
  def sources_of(events) = events.map(&:source)

  describe ".for" do
    it "returns chronologically-sorted events derived from StateTransition + record creation timestamps" do
      wf = job.workflows.last
      implement = wf.steps.find_by(kind: "implement")
      run = implement.runs.first || implement.runs.create!(job: job, trigger_kind: wf.trigger_kind)

      # Drive real AASM transitions so the audit log fills in.
      wf.start!;       wf.save!
      implement.start!; implement.save!
      run.start!;       run.save!
      run.succeed!;     run.save!
      implement.succeed!; implement.save!
      wf.succeed!;      wf.save!

      events = described_class.for(job)
      timestamps = events.map(&:at).compact
      expect(timestamps).to eq(timestamps.sort)

      expect(sources_of(events)).to include("workflow", "step", "run")

      titles = titles_of(events).join(" | ")
      expect(titles).to include("Workflow ##{wf.id} (initial) created")
      expect(titles).to include("Workflow ##{wf.id} started")
      expect(titles).to include("Workflow ##{wf.id} succeeded")
      expect(titles).to include("Step implement started")
      expect(titles).to include("Step implement succeeded")
      expect(titles).to include("Run ##{run.id} created (initial)")
      expect(titles).to include("Run ##{run.id} started")
      expect(titles).to include("Run ##{run.id} succeeded")
    end

    it "kinds reflect terminal state (success/failure/cancel)" do
      wf = job.workflows.last
      step = wf.steps.find_by(kind: "implement")
      run  = step.runs.first || step.runs.create!(job: job, trigger_kind: wf.trigger_kind)

      wf.start!;   wf.save!
      step.start!; step.save!
      run.start!;  run.save!
      run.fail!;   run.save!

      events = described_class.for(job)
      failure_titles = events.select { |e| e.kind == :failure }.map(&:title)
      expect(failure_titles).to include("Workflow ##{wf.id} failed",
                                       "Step implement failed",
                                       "Run ##{run.id} failed")
    end

    it "includes outcome + turns + duration in run finish detail" do
      wf = job.workflows.last
      run = wf.first_step.runs.first
      run.start!
      run.update!(agent_outcome: "success", agent_turns: 12)
      run.update_columns(started_at: 90.seconds.ago)
      run.succeed!
      run.update_columns(finished_at: Time.current)
      run.save!

      events = described_class.for(job)
      finish_event = events.find { |e| e.title == "Run ##{run.id} succeeded" }
      expect(finish_event).not_to be_nil
      expect(finish_event.detail).to include("outcome=success")
      expect(finish_event.detail).to include("turns=12")
      expect(finish_event.detail).to include("duration 1m30s")
    end

    it "doesn't blow up on records that never started or finished" do
      events = described_class.for(job)
      expect(events).not_to be_empty
      # First event must be one of the creation markers (Workflow or Run
      # created), since the factory leaves the initial Run in :queued
      # with no state transitions on Workflow/Step/Run.
      expect(events.first.title).to match(/created|→/)
    end

    it "includes the Run id in event refs for drill-downs" do
      run = job.initial_run
      events = described_class.for(job)
      run_event = events.find { |e| e.source == "run" }
      expect(run_event.ref[:run_id]).to eq(run.id)
      expect(run_event.ref[:workflow_id]).to be_present
      expect(run_event.ref[:step_id]).to be_present
    end

    it "includes failure classification and auto-retry scheduling decisions" do
      workflow = job.latest_workflow
      run = job.initial_run
      workflow.update!(
        state: "failed",
        failure_count: 1,
        finished_at: Time.zone.parse("2026-06-02 12:00:00"),
        artifacts: {
          "failure_classification" => "transient_provider_error",
          "failure_retryable" => true,
          "next_auto_retry_at" => "2026-06-02T12:30:00Z"
        }
      )
      JobLog.append!(run: run, chunk: "auto-retry scheduled after classification", kind: "system")

      events = described_class.for(job)

      expect(titles_of(events)).to include(
        "Failure classified: Transient provider error",
        "Auto-retry scheduled",
        "Retry decision recorded"
      )
      expect(events.find { |event| event.title == "Failure classified: Transient provider error" }.detail).to include("attempts=1/#{AppSetting.max_job_failures}")
    end

    it "surfaces Job state transitions (which the timestamp-derived view couldn't show)" do
      wf = job.workflows.last
      wf.start!; wf.save!

      events = described_class.for(job)
      job_events = events.select { |e| e.source == "job" }
      expect(job_events).not_to be_empty
      # propagate_start_to_job drove Job :queued → :running and tagged
      # the transition with source=propagate.
      running_event = job_events.find { |e| e.title.include?("→ running") }
      expect(running_event).not_to be_nil
      expect(running_event.transition_source).to eq("propagate")
    end
  end
end
