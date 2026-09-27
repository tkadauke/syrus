module OperatorBriefing
  class DiveInvestigateStep < ::Steps::Base
    def call
      workspace.setup
      run.update!(prompt: prompt) if run.prompt.blank?
      log("invoking agent for operator briefing dive investigation (#{workflow.slug})")
      run_agent(prompt: run.prompt)
    end

    private

    def prompt
      context = workflow.artifact("briefing_dive_context") || {}
      <<~PROMPT
        You are investigating a follow-up dive from the Operator Briefing for #{repository.slug}.

        The operator selected or clicked this briefing span:

        #{context["selected_text"].to_s.strip}

        Starting context:

        #{context["prompt"].to_s.strip}

        Evidence already attached to the briefing:

        ```json
        #{JSON.pretty_generate(context["evidence"] || [])}
        ```

        First call `read_briefing` to inspect the full briefing context, then inspect repository files and any relevant artifacts. The next step will ask you to submit the durable wiki-style dive report, so do not call `submit_dive_report` in this step.
      PROMPT
    end
  end
end
