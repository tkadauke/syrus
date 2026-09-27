module OperatorBriefing
  class SubmitDiveReportStep < ::Steps::Base
    TURN_BUDGET = 25

    def call
      workspace.setup
      return if workflow.artifact("briefing_dive_report").present?

      raise StepFailed, "#{workflow.slug} has no completed dive investigation run to report on" if missing_required_investigate_run?

      run.update!(prompt: prompt) if run.prompt.blank?
      log("invoking agent for submit_dive_report step (#{workflow.slug})")
      run_agent(
        prompt: run.prompt,
        max_turns: TURN_BUDGET,
        required_mcp_tools: %w[list_briefing_topics read_briefing_topic submit_dive_report]
      )
      workflow.reload
      verify_report!
    end

    private

    def prompt
      context = workflow.artifact("briefing_dive_context") || {}
      <<~PROMPT
        Turn the Operator Briefing dive investigation into a durable wiki-style topic revision.

        Before creating a new topic, call `list_briefing_topics` and check for a semantic match against existing topics for this repository. If a matching topic exists, pass its `topic_id` to `submit_dive_report`; otherwise pass a concise title and slug for a new topic.

        The original selected span was:

        #{context["selected_text"].to_s.strip}

        Call `submit_dive_report` with:
        - `title`: required for a new topic, optional when `topic_id` is present.
        - `slug`: optional new-topic slug; omit if unsure.
        - `topic_id`: existing topic id when there is a semantic match.
        - `narrative`: the full markdown report.
        - `findings`: optional list of concise findings.
        - `references`: optional list of evidence references.

        Do not create a duplicate near-match topic just because the title differs.
      PROMPT
    end

    def parent_session_id
      return nil if agent_resume_disabled?

      explicit_parent_session_id || successful_investigate_run&.provider_session&.session_id || super
    end

    def successful_investigate_run
      latest_succeeded_run_for("briefing_dive_investigate")
    end

    def missing_required_investigate_run?
      workflow.steps.exists?(kind: "briefing_dive_investigate") && successful_investigate_run.blank?
    end

    def verify_report!
      return if workflow.artifact("briefing_dive_report").present?

      capture_mcp_sidecar_stderr
      raise StepFailed, "agent didn't call submit_dive_report"
    end
  end
end
