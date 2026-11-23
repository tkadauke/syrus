# Reads the implementation classes plugins contribute through the Surface family,
# the only way a plugin can contribute them now that the legacy extension points
# are answered by the bridge. +capability+ is a Surface capability such as
# :sidebar_pages or :artifact_renderers.
module FamilyImplementationHelpers
  def surface_implementations(capability)
    Array(Syrus::Plugin::Dispatch.call(:surface, capability, Syrus::Plugin::Context::SurfaceContext.new)).flatten.compact
  end

  # The implementations one manifest contributes for a Surface capability,
  # whether or not its plugin is enabled.
  def manifest_surface_implementations(manifest, capability)
    declaration = manifest.family_provides.find { |entry| entry.family == :surface && entry.capabilities.include?(capability) }
    return [] unless declaration

    Array(Object.const_get(declaration.provider).public_send(capability, Syrus::Plugin::Context::SurfaceContext.new)).flatten.compact
  end
end

RSpec.configure { |config| config.include FamilyImplementationHelpers }

module ToolkitImplementationHelpers
  def workflow_tool_sets = Syrus::Plugin::Toolkit.workflow_tool_sets
  def chat_tool_sets = Syrus::Plugin::Toolkit.chat_tool_sets
  def permission_providers = Syrus::Plugin::Toolkit.permission_providers
end

RSpec.configure { |config| config.include ToolkitImplementationHelpers }
