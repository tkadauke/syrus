# Centralizes tool-selection logic for both sidecars.
# McpToolPolicy.for(context) returns the full set of tool classes the agent
# may use for the given context. Tool exposure rules live in McpToolRegistry;
# this policy remains the stable authorization facade for callers and tools.
class McpToolPolicy
  def self.for(context)
    new(context).allowed_tools
  end

  # Returns true when a context's role holds the named workflow capability.
  # Non-workflow roles always return false so the check is safe to call for any context.
  def self.capability_permitted?(context, capability)
    McpToolRegistry.capability_permitted?(context, capability)
  end

  def initialize(context)
    @context = context
  end

  def allowed_tools
    McpToolRegistry.tools_for_context(@context)
  end
end
