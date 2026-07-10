class GraderChatReporter
  # Post grader failure results to the chat and trigger an agent turn so the
  # agent can address the failures in context. Keeps linked_chat_id intact
  # so a follow-up complete_implement_step re-runs graders on the fixed code.
  def self.report_failure(workflow:, chat:)
    new(workflow, chat).report_failure
  end

  # Post a success notice to the chat. linked_chat_id is cleared by
  # Workflows::CodingHandoff#after_success before this is called.
  def self.report_success(workflow:, chat:)
    new(workflow, chat).report_success
  end

  def initialize(workflow, chat)
    @workflow = workflow
    @chat = chat
  end

  def report_failure
    text = failure_report_text

    # System message: displayed in the chat UI as an informational record
    # of the grader run. Included in agent history via important_system_message?.
    @chat.messages.create!(
      role: "system",
      content: { "text" => text, "source" => "grader_report", "workflow_id" => @workflow.id }
    )

    # Queued user message: triggers the agent turn. Agent reads the system
    # message in history and the grader details below to fix the failures.
    trigger_text = "Graders have run and some required checks failed. " \
                   "Please review the results above and fix the issues, " \
                   "then call `complete_implement_step` when you're ready to re-run."
    enqueue_agent_turn(trigger_text)
  end

  def report_success
    pr_url = App::Presentation.job_pr_url(@workflow.job)
    pr_link = pr_url ? " [View PR](#{pr_url})" : ""

    text = "All graders passed — your PR has been opened.#{pr_link}"
    @chat.messages.create!(
      role: "system",
      content: { "text" => text, "source" => "grader_report", "workflow_id" => @workflow.id }
    )
  end

  private

  def failure_report_text
    iterations = Array(@workflow.artifact("iterations"))
    graders = iterations.last || []

    lines = [ "## Grader results" ]
    lines << ""

    if graders.empty?
      lines << "_No grader data recorded._"
    else
      graders.each do |g|
        passed = g["status"] == "passed"
        icon = passed ? "✓" : "✗"
        req_label = g["required"] ? " *(required)*" : ""
        dur = g["duration_s"] ? " — #{g["duration_s"]}s" : ""
        lines << "#{icon} **#{g["name"]}**#{req_label}#{dur}"

        if !passed && g["output"].present?
          lines << "```"
          lines << g["output"].strip
          lines << "```"
        end
        lines << ""
      end
    end

    lines << "Fix the issues above and call `complete_implement_step` to re-run graders."
    lines.join("\n")
  end

  def enqueue_agent_turn(text)
    @chat.queued_messages.create!(content: { "text" => text, "source" => "grader_report" })
    ChatQueuedMessagePromoter.deliver_one_if_idle!(@chat)
  rescue StandardError => e
    Rails.logger.warn("[GraderChatReporter] failed to enqueue agent turn for chat #{@chat.id}: #{e.class}: #{e.message}")
  end
end
