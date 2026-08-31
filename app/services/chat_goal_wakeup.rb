require "json"

class ChatGoalWakeup
  SOURCE_KIND_PREFIX = "goal_".freeze

  def self.publish_start!(goal)
    goal.reload
    new(goal: goal).publish!(
      kind: "goal_started",
      subject: "Goal started",
      summary: "Goal #{goal.id} was started.",
      dedupe_key: "goal:#{goal.id}:start:#{goal.updated_at.utc.iso8601(6)}",
      work_state: { "action" => "start" }
    )
  end

  def self.publish_control!(goal, action:)
    new(goal: goal).publish!(
      kind: "goal_#{action}",
      subject: "Goal #{action}",
      summary: "Goal #{goal.id} was #{action}.",
      dedupe_key: "goal:#{goal.id}:control:#{action}:#{goal.updated_at.to_i}",
      work_state: { "action" => action }
    )
  end

  def self.publish_work_event!(goal:, kind:, subject:, summary:, repository: nil, job: nil, epic: nil, proposal: nil, work_state: {}, dedupe_key:)
    new(goal: goal).publish!(
      kind: "#{SOURCE_KIND_PREFIX}#{kind}",
      subject: subject,
      summary: summary,
      repository: repository,
      job: job,
      epic: epic,
      proposal: proposal,
      work_state: work_state,
      dedupe_key: dedupe_key
    )
  end

  def initialize(goal:)
    @goal = goal
    @chat_session = goal.chat_session
  end

  def publish!(kind:, subject:, summary:, repository: nil, job: nil, epic: nil, proposal: nil, work_state: {}, dedupe_key:)
    return unless @goal&.active?

    event = nil
    created = false
    ChatScopedEvent.transaction(requires_new: true) do
      event = ChatScopedEvent.record!(
        chat_session: @chat_session,
        source_kind: kind,
        payload: payload_for(kind, subject, summary, work_state),
        repository: repository || job&.repository || epic&.repository || @goal.repository,
        job: job,
        epic: epic,
        proposal: proposal,
        dedupe_key: dedupe_key
      )
      created = event.previously_new_record?
    end
    return event unless created

    enqueue_continuation!(event)
    event
  end

  private

  def payload_for(kind, subject, summary, work_state)
    {
      "kind" => kind,
      "severity" => "info",
      "subject" => subject,
      "summary" => summary,
      "goal" => {
        "id" => @goal.id,
        "prompt" => @goal.prompt,
        "completion_condition" => @goal.completion_condition,
        "mode_snapshot" => @goal.mode_snapshot,
        "approval_policy" => @goal.approval_policy,
        "auto_file_proposals" => @goal.auto_file_proposals?,
        "auto_submit_jobs" => @goal.auto_submit_jobs?,
        "iteration_count" => @goal.iteration_count.to_i
      },
      "work_state" => work_state.presence || {},
      "occurred_at" => Time.current.iso8601
    }
  end

  def enqueue_continuation!(event)
    return unless @goal.reload.active?
    return if @chat_session.reload.stop_requested_at?

    signature = signature_for(event)
    if blocked_boundary?(event)
      blocked_count = @goal.record_blocked_event!(signature: signature)
      if blocked_count >= ChatGoal::MAX_CONSECUTIVE_BLOCKED_EVENTS
        @goal.block!(
          reason: "repeated_blocked_state",
          details: { "signature" => signature, "event_id" => event.id }
        )
        audit_message!("Goal blocked after #{blocked_count} repeated blocked wake events.")
        return
      end
    else
      @goal.record_progress!(signature: signature)
    end

    @goal.increment!(:iteration_count)
    @chat_session.chat_queued_messages.create!(
      content: {
        "text" => continuation_display_text(event),
        "internal_prompt" => continuation_prompt(event),
        "requested_by" => "goal",
        "source" => "goal_continuation",
        "goal_continuation" => true,
        "chat_goal_id" => @goal.id,
        "chat_scoped_event_id" => event.id,
        "iteration" => @goal.iteration_count
      }
    )
    ChatQueuedMessagePromoter.deliver_one_if_idle!(@chat_session)
  end

  def continuation_display_text(event)
    return "Goal resumed. Continuing..." if event.payload.dig("work_state", "action") == "resume"

    "Goal continuation started."
  end

  def blocked_boundary?(event)
    text = [ event.source_kind, event.payload["summary"], event.payload.dig("work_state", "state") ].compact.join(" ")
    text.match?(/blocked|failed|cancelled|closed_without_merge|archived/i)
  end

  def continuation_prompt(event)
    if event.source_kind == "goal_started"
      return <<~PROMPT.strip
        Begin work immediately under the newly active goal.

        Event:
        #{JSON.pretty_generate(event.payload)}

        Decide the first useful step toward the goal and take it now. If the goal is already complete, call mark_goal_completed. If progress is blocked and you cannot continue without operator input or an external change, call mark_goal_blocked with a concise reason. Otherwise continue working under the goal policy.
      PROMPT
    end

    <<~PROMPT.strip
      Continue the active goal after this goal-linked work boundary.

      Event:
      #{JSON.pretty_generate(event.payload)}

      Decide the next useful step toward the goal. If the goal is complete, call mark_goal_completed. If progress is blocked and you cannot continue without operator input or an external change, call mark_goal_blocked with a concise reason. Otherwise continue working under the goal policy.
    PROMPT
  end

  def signature_for(event)
    [
      event.source_kind,
      event.job_id,
      event.epic_id,
      event.proposal_id,
      event.payload.dig("work_state", "state"),
      event.payload.dig("work_state", "closure_reason")
    ].compact.join(":").presence || "event:#{event.id}"
  end

  def audit_message!(text)
    @chat_session.messages.create!(
      role: "system",
      content: {
        "text" => text,
        "source" => "goal_loop",
        "chat_goal_id" => @goal.id
      }
    )
  end
end
