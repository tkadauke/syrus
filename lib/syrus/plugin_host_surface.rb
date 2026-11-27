module Syrus
  class PluginHostSurface
    # Keep exceptions rare and document why a stable public contract cannot be
    # exposed. Entries are exact constant names; wildcard exemptions are not
    # supported. There are currently no exceptions.
    INTENTIONAL_INTERNAL_REFERENCES = {}.freeze

    def public?(name)
      name = name.to_s
      return true if name == "Syrus::Host"

      Syrus::Host.apis.any? do |api|
        public_names(api).any? { |public_name| name == public_name || name.start_with?("#{public_name}::") }
      end || documented_plugin_interfaces.any? { |public_name| name == public_name || name.start_with?("#{public_name}::") }
    end

    def allowed_internal?(name) = INTENTIONAL_INTERNAL_REFERENCES.key?(name.to_s)

    private

    def public_names(api)
      target_name = api.name.safe_constantize.then { |target| target.respond_to?(:name) && target.is_a?(Module) ? target.name : nil }
      [ api.name, target_name ].compact.uniq
    end

    def documented_plugin_interfaces
      @documented_plugin_interfaces ||= [
        *Syrus::PluginRegistry::INTERFACE_FOR.values.filter_map { |resolver| resolver.call.name },
        "Syrus::PluginApi",
        "Syrus::Plugin::CliCommandHandler"
      ].uniq
    end
  end
end
