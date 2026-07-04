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
      expect(titles).to include("WF-#{wf.id} (initial) created")
      expect(titles).to include("WF-#{wf.id} started")
      expect(titles).to include("WF-#{wf.id} succeeded")
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
      expect(failure_titles).to include("WF-#{wf.id} failed",
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

    describe "feedback iteration events" do
      it "emits a numbered workflow-level iteration event for each pr_comment workflow" do
        Workflow.create!(job: job, trigger_kind: "pr_comment", state: "succeeded",
                         created_at: 2.hours.ago,
                         artifacts: { "pr_feedback_iteration" => 1, "pr_feedback_auto" => true,
                                      "pr_feedback_source_handle" => "alice" })
        Workflow.create!(job: job, trigger_kind: "pr_comment", state: "succeeded",
                         created_at: 1.hour.ago,
                         artifacts: { "pr_feedback_iteration" => 2, "pr_feedback_auto" => false,
                                      "pr_feedback_source_handle" => "bob" })

        events = described_class.for(job)
        iteration_events = events.select { |e| e.source == "feedback" && e.title.include?("iteration") }

        expect(iteration_events.size).to be >= 2
        titles = iteration_events.map(&:title)
        expect(titles).to include(a_string_matching(/Feedback iteration 1.*auto/))
        expect(titles).to include(a_string_matching(/Feedback iteration 2.*confirmed/))
      end

      it "includes triggering comment handle in the iteration event title" do
        Workflow.create!(job: job, trigger_kind: "pr_comment", state: "succeeded",
                         created_at: 1.hour.ago,
                         artifacts: { "pr_feedback_iteration" => 1, "pr_feedback_auto" => true,
                                      "pr_feedback_source_handle" => "alice-reviewer" })

        events = described_class.for(job)
        iter_event = events.find { |e| e.source == "feedback" && e.title.include?("iteration 1") }

        expect(iter_event).not_to be_nil
        expect(iter_event.title).to include("@alice-reviewer")
      end

      it "falls back to ordinal index when pr_feedback_iteration artifact is missing" do
        Workflow.create!(job: job, trigger_kind: "pr_comment", state: "succeeded",
                         created_at: 2.hours.ago, artifacts: {})
        Workflow.create!(job: job, trigger_kind: "pr_comment", state: "succeeded",
                         created_at: 1.hour.ago, artifacts: {})

        events = described_class.for(job)
        iteration_events = events.select { |e| e.source == "feedback" && e.kind == :start }

        titles = iteration_events.map(&:title)
        expect(titles).to include(a_string_matching(/Feedback iteration 1/))
        expect(titles).to include(a_string_matching(/Feedback iteration 2/))
      end

      it "emits per-comment action events for actioned PrReviewComments" do
        pr_comment = PrReviewComment.create!(
          job: job,
          pr_type: "direct",
          comment_kind: "issue",
          github_comment_id: 42,
          github_handle: "reviewer",
          attributed_to: "external",
          actionable: true,
          actioned_at: 1.hour.ago,
          actioned_by: "auto_poll"
        )

        events = described_class.for(job)
        comment_events = events.select { |e| e.source == "feedback" && e.title.include?("actioned") }

        expect(comment_events.size).to eq(1)
        expect(comment_events.first.title).to include("automatically")
        expect(comment_events.first.detail).to include("@reviewer")
      end

      it "marks ignored comments as :cancel kind" do
        PrReviewComment.create!(
          job: job,
          pr_type: "direct",
          comment_kind: "issue",
          github_comment_id: 99,
          github_handle: "outsider",
          attributed_to: "external",
          actionable: true,
          actioned_at: 1.hour.ago,
          actioned_by: "operator:ignore"
        )

        events = described_class.for(job)
        ignore_event = events.find { |e| e.source == "feedback" && e.kind == :cancel }
        expect(ignore_event).not_to be_nil
        expect(ignore_event.title).to include("ignored by operator")
      end

      it "includes chat_feedback workflows in iteration numbering" do
        Workflow.create!(job: job, trigger_kind: "pr_comment", state: "succeeded",
                         created_at: 2.hours.ago,
                         artifacts: { "pr_feedback_iteration" => 1, "pr_feedback_auto" => true })
        Workflow.create!(job: job, trigger_kind: "chat_feedback", state: "succeeded",
                         created_at: 1.hour.ago,
                         artifacts: { "pr_feedback_iteration" => 2, "pr_feedback_auto" => false })

        events = described_class.for(job)
        iteration_events = events.select { |e| e.source == "feedback" && e.kind == :start }

        expect(iteration_events.size).to eq(2)
        expect(iteration_events.map(&:title)).to include(
          a_string_matching(/Feedback iteration 1.*auto/),
          a_string_matching(/Feedback iteration 2.*confirmed/)
        )
      end
    end
  end
end
