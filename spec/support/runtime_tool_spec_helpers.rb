module RuntimeToolSpecHelpers
  def enable_coding_mode!(enabled: true)
    feature = Feature.find_or_create_by!(slug: "coding_mode") do |record|
      record.category = "Labs"
      record.name = "Coding Mode"
    end
    feature.update!(enabled: enabled)
  end

  # Registers a minimal RuntimeSessionProvider (DOC-17) for the runtime_*
  # tool specs, via PluginRegistry's lightweight "direct form" registration
  # (see spec/services/runtime_session_providers_spec.rb for the same
  # pattern) -- no bundled plugin gem or real dev server/browser required.
  def register_stub_runtime_provider!
    Syrus::PluginRegistry.register(:runtime_session_provider, stub_runtime_provider_class)
  end

  def stub_runtime_provider_class
    @stub_runtime_provider_class ||= Class.new do
      include Syrus::Plugin::RuntimeSessionProvider

      def self.provider_key = "stub"
      def self.display_name = "Stub Provider"
      def self.detect(_repository, config) = config[:workspace_path].present?
      def self.capabilities(_repository, _config) = { stream: "screenshot", input: %w[pointer] }

      def start_session(workspace_ref, _config) = { workspace_ref: workspace_ref, pid: 123, port: 4000 }
      def build_or_reload(_session_id, _options) = { reloaded: true }
      def launch(_session_id, options) = { launched: true, options: options }
      def snapshot(_session_id, options) = { snapshot: true, options: options }
      def inspect(_session_id = nil, _options = nil) = { tree: [] }

      def input(session_id, event)
        runtime_session = RuntimeSession.find(session_id)
        return { error: "lease_required" } unless runtime_session.active_agent_input_lease

        { delivered: event }
      end

      def logs(_session_id, cursor, _options) = { entries: [ "line-#{cursor}" ], cursor: cursor.to_i + 1 }
      def stop_session(_session_id) = true
    end
  end
end

RSpec.configure do |config|
  config.include RuntimeToolSpecHelpers
end
