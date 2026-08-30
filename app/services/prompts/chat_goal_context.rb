require "json"

module Prompts
  class ChatGoalContext
    def initialize(chat_session:, current_message:)
      @chat_session = chat_session
      @current_message = current_message
      @goal = chat_session.active_goal
    end

    def to_s
      return unless @goal&.active?

      <<~PROMPT.strip
        Active goal:
        #{JSON.pretty_generate(goal_payload)}

        Goal-loop instructions:
        - Work toward the active goal until its completion condition is met, the operator pauses/stops it, or you are truly blocked.
        - Respect the current mode and policy fields. In planning mode, use proposal tools and only file work when auto_file_proposals is true or the operator explicitly confirms. In coding/local mode, only submit implementation work when auto_submit_jobs is true or the operator explicitly confirms.
        - When the goal is complete, call mark_goal_completed with a concise reason.
        - When progress is blocked and cannot continue without operator input or an external state change, call mark_goal_blocked with a concise reason and details.
      PROMPT
    end

    private

    def goal_payload
      {
        id: @goal.id,
        prompt: @goal.prompt,
        completion_condition: @goal.completion_condition,
        status: @goal.status,
        mode: @goal.mode_snapshot && @goal.mode_snapshot["mode"],
        mode_snapshot: @goal.mode_snapshot,
        approval_policy: @goal.approval_policy,
        auto_file_proposals: @goal.auto_file_proposals?,
        auto_submit_jobs: @goal.auto_submit_jobs?,
        iteration_number: @goal.iteration_count.to_i,
        loop_safeguards: {
          consecutive_no_op_iterations: @goal.consecutive_no_op_iterations.to_i,
          max_consecutive_no_op_iterations: ChatGoal::MAX_CONSECUTIVE_NO_OP_ITERATIONS,
          consecutive_blocked_events: @goal.consecutive_blocked_events.to_i,
          max_consecutive_blocked_events: ChatGoal::MAX_CONSECUTIVE_BLOCKED_EVENTS
        },
        active_work_state: active_work_state,
        current_message: current_message_state
      }.compact
    end

    def active_work_state
      {
        proposals: @goal.chat_session.proposals.where(chat_goal_id: @goal.id).order(created_at: :desc).limit(10).map do |proposal|
          {
            id: proposal.id,
            slug: proposal.slug,
            kind: proposal.kind,
            state: proposal.state,
            title: proposal.title,
            job_id: proposal.job_id,
            epic_id: proposal.epic_id
          }.compact
        end,
        jobs: Job.where(chat_goal_id: @goal.id).order(created_at: :desc).limit(10).map do |job|
          {
            id: job.id,
            slug: job.slug,
            state: job.state,
            title: job.issue_title,
            pr_number: job.pr_number,
            closure_reason: job.closure_reason
          }.compact
        end,
        epics: Epic.where(chat_goal_id: @goal.id).order(created_at: :desc).limit(10).map do |epic|
          {
            id: epic.id,
            slug: epic.slug,
            state: epic.state,
            title: epic.title,
            done_at: epic.done_at&.iso8601
          }.compact
        end
      }
    end

    def current_message_state
      return unless @current_message&.content.is_a?(Hash)

      @current_message.content.slice(
        "requested_by",
        "source",
        "goal_continuation",
        "chat_goal_id",
        "chat_scoped_event_id",
        "iteration"
      ).compact
    end
  end
end
