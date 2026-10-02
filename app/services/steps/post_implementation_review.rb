module Steps
  # Generic host step for plugin-supplied review-note generation.
  # Core owns the workflow slot and agent invocation; plugins own the prompt,
  # MCP tool set, persistence, and later review-tab rendering.
  # Providers that request this step must expose their required submission
  # tools in the same run MCP context, and the agent must call them even for an
  # empty result.
  class PostImplementationReview < Base
    TURN_BUDGET = 25

    def call
      workspace.setup
      active_providers = providers
      if active_providers.empty?
        log("[post_implementation_review] no enabled providers requested review notes - skipping")
        return
      end

      run.update!(prompt: prompt_for(active_providers)) if run.prompt.blank?
      tools = required_mcp_tools_for(active_providers)
      log("invoking agent for post_implementation_review step (#{workflow.slug})")

      run_agent(
        prompt: run.prompt,
        max_turns: TURN_BUDGET,
        required_mcp_tools: tools.presence,
        enforce_required_mcp_tools: tools.present?
      )
    end

    private

    def providers
      Syrus::PluginRegistry.providers_for(:post_implementation_review_provider).select do |provider|
        provider.review_needed?(job: job, trigger_kind: workflow.trigger_kind)
      rescue StandardError => e
        log("[post_implementation_review] #{provider}.review_needed? failed: #{e.class}: #{e.message}")
        false
      end
    end

    def prompt_for(active_providers)
      sections = active_providers.flat_map do |provider|
        Array(provider.prompt_sections(job: job, workflow: workflow, run: run))
      rescue StandardError => e
        log("[post_implementation_review] #{provider}.prompt_sections failed: #{e.class}: #{e.message}")
        []
      end.map(&:to_s).reject(&:blank?)

      if sections.empty?
        <<~PROMPT.strip
          Review the final implementation diff and call the required plugin MCP tool(s) with any review notes.
          If there are no notable ranges, submit an empty result through the plugin tool instead of changing files.
        PROMPT
      else
        sections.join("\n\n")
      end
    end

    def required_mcp_tools_for(active_providers)
      active_providers.flat_map do |provider|
        Array(provider.required_mcp_tools(job: job, workflow: workflow, run: run))
      rescue StandardError => e
        log("[post_implementation_review] #{provider}.required_mcp_tools failed: #{e.class}: #{e.message}")
        []
      end.map(&:to_s).reject(&:blank?).uniq
    end

    def parent_session_id
      return nil if agent_resume_disabled?

      explicit_parent_session_id || implementation_session_id || super
    end

    def implementation_session_id
      latest_succeeded_run_for(%w[implement respond])&.provider_session&.session_id
    end
  end
end
