module Jobs
  # Builds a flat, chronological event feed for a Job. Sources:
  #
  # - StateTransition rows for Job/Workflow/Step/Run AASM transitions.
  #   This is the canonical answer to "what state moved when, why,
  #   by whom" — fed by RecordsStateTransitions on every transition.
  # - Record creation timestamps for Workflows and Runs (so the
  #   narrative starts with "Workflow N created" before "Workflow
  #   N started"; the audit log only fires once the AASM `start`
  #   event runs).
  # - Run agent metadata (turns, cost, outcome) attached to the
  #   Run's terminal transition event so operators see a single
  #   "Run finished" line with the cost/duration breakdown.
  #
  # Each event is a Data with:
  #   :at                  — Time
  #   :kind                — :info | :start | :success | :failure | :cancel
  #   :source              — "job" | "workflow" | "step" | "run"
  #   :transition_source   — "aasm" | "propagate" | "reconciler" | "operator" | "system" | nil
  #   :title               — short human description
  #   :detail              — optional secondary text
  #   :ref                 — { workflow_id:, step_id:, run_id: } for drill-down
  class Timeline
    Event = Data.define(:at, :kind, :source, :transition_source, :title, :detail, :ref)

    def self.for(job)
      new(job).events
    end

    def initialize(job)
      @job = job
    end

    def events
      out = []
      out.concat(creation_events)
      out.concat(transition_events)
      out.concat(retry_decision_events)
      out.concat(feedback_iteration_events)
      out.compact.sort_by { |e| [ e.at || Time.zone.at(0), source_order(e.source) ] }
    end

    private

    def source_order(source)
      # Stable tie-break when multiple events share a timestamp.
      # Created-at sorts before AASM start for the same record.
      %w[ job workflow step run retry feedback ].index(source) || 99
    end

    def creation_events
      events = []

      @job.workflows.order(:created_at).each do |wf|
        events << Event.new(
          at: wf.created_at, kind: :info, source: "workflow",
          transition_source: nil,
          title: "#{wf.slug} (#{wf.trigger_kind}) created",
          detail: nil,
          ref: { workflow_id: wf.id }
        )
      end

      Run.where(job_id: @job.id).order(:created_at).each do |run|
        events << Event.new(
          at: run.created_at, kind: :info, source: "run",
          transition_source: nil,
          title: "Run ##{run.id} created (#{run.trigger_kind})",
          detail: nil,
          ref: { workflow_id: run.step&.workflow_id, step_id: run.step_id, run_id: run.id }
        )
      end

      events
    end

    def transition_events
      transitions = fetch_transitions
      transitions.map { |t| event_for_transition(t) }
    end

    def retry_decision_events
      events = []
      events.concat(retry_artifact_events)
      events.concat(retry_log_events)
      events
    end

    def retry_artifact_events
      workflow = @job.workflows.where(state: "failed").order(created_at: :desc, id: :desc).first
      return [] unless workflow

      state = App::RetryState.for(@job)
      return [] if state[:classification].blank? && state[:next_auto_retry_at].blank? && !state[:auto_retry_exhausted] && !state[:provider_circuit_open]

      at = workflow.finished_at || workflow.updated_at || workflow.created_at
      detail = [
        "classification=#{state[:classification_label]}",
        ("retryable=#{state[:retryable]}" unless state[:retryable].nil?),
        "attempts=#{state[:retry_attempt_count]}/#{state[:retry_budget]}",
        ("remaining=#{state[:retry_budget_remaining]}" if state[:retry_budget_remaining]),
        ("next=#{state[:next_auto_retry_at]}" if state[:next_auto_retry_at]),
        ("delayed_until=#{state[:retry_delayed_until]}" if state[:retry_delayed_until]),
        state[:retry_delay_reason]
      ].compact.join(" · ")

      [
        Event.new(
          at: at,
          kind: retry_event_kind(state),
          source: "retry",
          transition_source: "system",
          title: "Failure classified: #{state[:classification_label]}",
          detail: detail.presence,
          ref: { workflow_id: workflow.id }
        ),
        retry_schedule_event(state, workflow, at)
      ].compact
    end

    def retry_schedule_event(state, workflow, at)
      title =
        if state[:auto_retry_exhausted]
          "Auto-retry exhausted"
        elsif state[:provider_circuit_open]
          "Auto-retry delayed by provider circuit"
        elsif state[:next_auto_retry_at].present?
          "Auto-retry scheduled"
        end
      return unless title

      Event.new(
        at: at,
        kind: retry_event_kind(state),
        source: "retry",
        transition_source: "system",
        title: title,
        detail: state[:state_label],
        ref: { workflow_id: workflow.id }
      )
    end

    def retry_log_events
      run_ids = Run.where(job_id: @job.id).pluck(:id)
      return [] if run_ids.empty?

      JobLog.where(run_id: run_ids, kind: "system")
            .where("chunk LIKE ? OR chunk LIKE ? OR chunk LIKE ? OR chunk LIKE ?",
                   "%classification%", "%auto-retry%", "%retry scheduled%", "%circuit%")
            .order(:created_at, :sequence)
            .map do |log|
        run = log.run
        Event.new(
          at: log.created_at,
          kind: :info,
          source: "retry",
          transition_source: "system",
          title: "Retry decision recorded",
          detail: log.chunk.to_s.truncate(240),
          ref: { workflow_id: run.step&.workflow_id, step_id: run.step_id, run_id: run.id }
        )
      end
    end

    def retry_event_kind(state)
      return :failure if state[:auto_retry_exhausted]
      return :cancel if state[:provider_circuit_open]
      return :start if state[:next_auto_retry_at].present?

      :info
    end

    def fetch_transitions
      job_id = @job.id
      workflow_ids = @job.workflows.pluck(:id)
      step_ids = Step.where(workflow_id: workflow_ids).pluck(:id)
      run_ids = Run.where(job_id: job_id).pluck(:id)

      scope = StateTransition.where(
        "(subject_type = 'Job' AND subject_id = :job_id) OR " \
        "(subject_type = 'Workflow' AND subject_id IN (:workflow_ids)) OR " \
        "(subject_type = 'Step' AND subject_id IN (:step_ids)) OR " \
        "(subject_type = 'Run' AND subject_id IN (:run_ids))",
        job_id: job_id,
        workflow_ids: workflow_ids.presence || [ 0 ],
        step_ids: step_ids.presence || [ 0 ],
        run_ids: run_ids.presence || [ 0 ]
      )
      scope.order(:created_at).to_a
    end

    def event_for_transition(t)
      source = t.subject_type.downcase
      ref = ref_for(t)
      detail = detail_for_transition(t)

      Event.new(
        at: t.created_at,
        kind: kind_for(t.to_state),
        source: source,
        transition_source: t.source,
        title: title_for(t),
        detail: detail,
        ref: ref
      )
    end

    def ref_for(t)
      case t.subject_type
      when "Job"      then { job_id: t.subject_id }
      when "Workflow" then { workflow_id: t.subject_id }
      when "Step"
        step = Step.find_by(id: t.subject_id)
        { workflow_id: step&.workflow_id, step_id: t.subject_id }
      when "Run"
        run = Run.find_by(id: t.subject_id)
        { workflow_id: run&.step&.workflow_id, step_id: run&.step_id, run_id: t.subject_id }
      else
        {}
      end
    end

    def title_for(t)
      verb = lifecycle_verb(t)

      case t.subject_type
      when "Job"
        # Job's AASM event names (start_running / mark_implemented /
        # retry_after_failure) don't conjugate cleanly into past-tense
        # verbs, so render Job transitions as explicit state moves.
        "Job state #{t.from_state} → #{t.to_state}"
      when "Workflow"
        slug = Workflow.find_by(id: t.subject_id)&.slug || "WF-#{t.subject_id}"
        verb ? "#{slug} #{verb}" :
               "#{slug} #{t.from_state} → #{t.to_state}"
      when "Step"
        step = Step.find_by(id: t.subject_id)
        kind = step&.kind || "?"
        verb ? "Step #{kind} #{verb}" : "Step #{kind} #{t.from_state} → #{t.to_state}"
      when "Run"
        verb ? "Run ##{t.subject_id} #{verb}" :
               "Run ##{t.subject_id} #{t.from_state} → #{t.to_state}"
      else
        "#{t.subject_type}##{t.subject_id} #{t.from_state} → #{t.to_state}"
      end
    end

    # Past-tense verbs for the Workflow/Step/Run AASM events.
    # Returns nil when the event name is missing or not in the
    # standard set — caller falls back to the from → to form.
    def lifecycle_verb(t)
      case t.event_name
      when "start"  then "started"
      when "succeed" then "succeeded"
      when "fail"   then "failed"
      when "cancel" then "cancelled"
      when "reopen" then "reopened"
      end
    end

    def detail_for_transition(t)
      bits = []
      bits << t.event_name if t.event_name.present?

      if t.subject_type == "Run" && %w[ succeeded failed cancelled ].include?(t.to_state)
        run = Run.find_by(id: t.subject_id)
        if run
          bits << "outcome=#{run.agent_outcome}" if run.agent_outcome.present?
          bits << "turns=#{run.agent_turns}" if run.agent_turns
          if run.started_at && run.finished_at
            bits << "duration #{format_duration(run.started_at, run.finished_at)}"
          end
        end
      end

      bits.join(" · ").presence
    end

    def kind_for(to_state)
      case to_state
      when "succeeded", "implemented", "approved", "merged" then :success
      when "failed"                                          then :failure
      when "cancelled", "closed"                             then :cancel
      when "running", "landing"                              then :start
      else                                                        :info
      end
    end

    def feedback_iteration_events
      events = []
      events.concat(feedback_workflow_iteration_events)
      events.concat(feedback_comment_action_events)
      events
    end

    # One event per pr_comment / chat_feedback workflow — the "iteration started" marker.
    # Uses pr_feedback_iteration from workflow artifacts; falls back to ordinal position.
    def feedback_workflow_iteration_events
      @job.workflows
          .where(trigger_kind: %w[ pr_comment chat_feedback ])
          .order(:created_at, :id)
          .map.with_index(1) do |wf, ordinal|
        iteration = wf.artifact("pr_feedback_iteration") || ordinal
        auto      = wf.artifact("pr_feedback_auto")
        handle    = wf.artifact("pr_feedback_source_handle")

        title = "Feedback iteration #{iteration} started"
        source_clause = handle.present? ? " triggered by @#{handle}" : ""
        mode_clause   = auto.nil? ? "" : (auto ? " (auto)" : " (confirmed)")
        title += source_clause + mode_clause

        Event.new(
          at: wf.created_at,
          kind: :start,
          source: "feedback",
          transition_source: auto == false ? "operator" : "system",
          title: title,
          detail: nil,
          ref: { workflow_id: wf.id }
        )
      end
    end

    # One event per actioned PrReviewComment — shows individual comment attribution.
    def feedback_comment_action_events
      @job.pr_review_comments.where.not(actioned_at: nil).order(:actioned_at).map do |comment|
        actioned_by = comment.actioned_by.to_s
        auto = actioned_by == "auto_poll"
        operator_action = actioned_by.start_with?("operator:") ? actioned_by.delete_prefix("operator:") : nil

        title = if auto
          "PR comment actioned automatically (#{comment.attributed_to})"
        elsif operator_action == "ignore"
          "PR comment ignored by operator (#{comment.attributed_to})"
        elsif operator_action == "replace"
          "PR comment replaced by operator and applied (#{comment.attributed_to})"
        elsif operator_action == "apply"
          "PR comment applied by operator (#{comment.attributed_to})"
        else
          "PR comment actioned (#{comment.attributed_to})"
        end

        handle = comment.github_handle.present? ? "@#{comment.github_handle}" : nil
        detail = [ handle, comment.pr_type, actioned_by ].compact.join(" · ")

        Event.new(
          at: comment.actioned_at,
          kind: operator_action == "ignore" ? :cancel : :info,
          source: "feedback",
          transition_source: auto ? "system" : "operator",
          title: title,
          detail: detail.presence,
          ref: {}
        )
      end
    end

    def format_duration(start, finish)
      seconds = (finish - start).to_i
      return "#{seconds}s" if seconds < 60
      mins = seconds / 60
      "#{mins}m#{(seconds % 60).to_s.rjust(2, '0')}s"
    end
  end
end
