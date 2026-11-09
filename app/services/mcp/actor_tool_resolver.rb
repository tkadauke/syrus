module Mcp
  # Resolves the callable and capability descriptor for a non-coworker actor's
  # tool by name, for core registry tools and plugin-provided tools alike.
  #
  # Plugin tools are generated per-actor by the sidecar from tool-set
  # definitions and carry their descriptor on the tool itself; they never exist
  # in the static McpToolRegistry. Request creation, approval, authority
  # issuance and replay all go through here so the descriptor and the callable
  # can never disagree about whether a tool is available. The surface is
  # rebuilt on every call, so a disabled or removed plugin fails closed.
  module ActorToolResolver
    Resolution = Struct.new(:tool, :descriptor, keyword_init: true)

    module_function

    def resolve(tool_name:, chat_session: nil, run: nil)
      tool = actor_tools(chat_session:, run:).find { |candidate| McpToolRegistry.tool_name_for(candidate) == tool_name }
      if tool
        descriptor = McpToolRegistry.entry_for(tool)&.descriptor ||
          (tool.capability_descriptor if tool.respond_to?(:capability_descriptor))
        return Resolution.new(tool:, descriptor:) if descriptor
      end
      return if chat_session || run

      # No live actor to rebuild a surface for: only core registry entries can
      # be described.
      entry = McpToolRegistry.entries(surface: :workflow).find { |candidate| McpToolRegistry.tool_name_for(candidate.tool) == tool_name }
      Resolution.new(tool: entry.tool, descriptor: entry.descriptor) if entry
    end

    def actor_tools(chat_session:, run:)
      if chat_session
        Mcp::Sidecar.chat_tools(chat_session, tier: :all)
      elsif run
        context = McpToolContext.from_run(run)
        McpToolPolicy.for(context) + Mcp::Sidecar.plugin_workflow_tools_for(context)
      else
        []
      end
    end
  end
end
