module ConnectedAccounts
  ProviderDeclaration = Data.define(
    :plugin_name, :provider, :key, :display_name, :capabilities, :callback_route,
    :scopes, :supports_read_only, :configuration, :settings_notice, :settings_notice_i18n_key,
    :authorization_kind, :system_service_identities
  ) do
    RISK_LEVELS = %w[low medium high critical].freeze

    def self.build(plugin_name:, attributes:)
      values = attributes.to_h.stringify_keys
      new(
        plugin_name: plugin_name.to_s,
        provider: values["provider"],
        key: values["key"].to_s,
        display_name: values["display_name"].to_s,
        capabilities: Array(values["capabilities"]).map(&:to_s).freeze,
        callback_route: values["callback_route"].to_s,
        scopes: Array(values["scopes"]).map { |scope| scope.to_h.stringify_keys.freeze }.freeze,
        supports_read_only: values["supports_read_only"],
        configuration: values.fetch("configuration", {}).to_h.stringify_keys.freeze,
        settings_notice: values["settings_notice"].presence,
        settings_notice_i18n_key: values["settings_notice_i18n_key"].presence,
        authorization_kind: values.fetch("authorization_kind", "oauth").to_s,
        system_service_identities: Array(values["system_service_identities"]).map(&:to_s).freeze
      ).tap(&:validate!)
    end

    def validate!
      errors = []
      errors << "provider must name a constant" unless provider.is_a?(String) && provider.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/)
      errors << "key must be stable lower-case identifier" unless key.match?(/\A[a-z][a-z0-9_]*\z/)
      errors << "display_name is required" if display_name.blank?
      missing = Provider::REQUIRED_CAPABILITIES - capabilities
      unknown = capabilities - Provider::CAPABILITIES
      errors << "missing required capabilities: #{missing.join(', ')}" if missing.any?
      errors << "unknown capabilities: #{unknown.join(', ')}" if unknown.any?
      errors << "callback_route must be an absolute path" unless callback_route.start_with?("/")
      errors << "supports_read_only must be true or false" unless [ true, false ].include?(supports_read_only)
      errors << "authorization_kind must be oauth or token" unless %w[oauth token].include?(authorization_kind)
      invalid_services = system_service_identities.reject { |identity| identity.match?(/\A[a-z][a-z0-9_.:-]*\z/) }
      errors << "system service identities are invalid: #{invalid_services.join(', ')}" if invalid_services.any?
      errors.concat(scope_errors)
      raise ArgumentError, errors.join("; ") if errors.any?

      klass = provider.constantize
      if system_service_identities.any? && !klass.respond_to?(:register_system_access)
        errors << "#{provider} must implement .register_system_access(identity, binding)"
      end
      if system_service_identities.any? && !accepts_context?(klass, "system_invoke")
        errors << "#{provider} must implement .system_invoke(context)"
      end
      capabilities.each do |capability|
        errors << "#{provider} must implement .#{capability}(context)" unless accepts_context?(klass, capability)
      end
      raise ArgumentError, errors.join("; ") if errors.any?

      self
    rescue NameError => error
      raise ArgumentError, "provider #{provider.inspect} does not resolve (#{error.message})"
    end

    def token_authorization? = authorization_kind == "token"

    # Manifest-pinned API origins. A provider that declares them owns the
    # credential's target constraint; instance configuration cannot widen it.
    def api_origins = Array(configuration["api_origins"]).map(&:to_s)

    def call(capability, context)
      capability = capability.to_s
      raise ArgumentError, "provider does not declare #{capability}" unless capabilities.include?(capability)

      Invoker.call(provider: provider.constantize, capability: capability, context: context)
    end

    def connect_scope_keys
      klass = provider.constantize
      return klass.connect_scope_keys if klass.respond_to?(:connect_scope_keys)

      scopes.pluck("key")
    end

    def read_only_scope_keys
      klass = provider.constantize
      return klass.read_only_scope_keys if klass.respond_to?(:read_only_scope_keys)

      scopes.filter_map { |scope| scope["key"] if scope["read_only"] }
    end

    private

    def accepts_context?(klass, capability)
      return false unless klass.respond_to?(capability)

      parameters = klass.method(capability).parameters
      parameters.length == 1 && %i[req opt].include?(parameters.first.first)
    end

    def scope_errors
      errors = []
      errors << "at least one scope declaration is required" if scopes.empty?
      duplicate_keys = scopes.group_by { |scope| scope["key"] }.select { |_key, entries| entries.many? }.keys
      errors << "scope keys must be unique: #{duplicate_keys.join(', ')}" if duplicate_keys.any?
      scopes.each do |scope|
        key = scope["key"].to_s
        errors << "scope key is required" if key.blank?
        errors << "scope #{key.inspect} requires a label" if scope["label"].blank?
        errors << "scope #{key.inspect} has invalid risk" unless RISK_LEVELS.include?(scope["risk"].to_s)
        errors << "scope #{key.inspect} requires Syrus capabilities" if Array(scope["syrus_capabilities"]).empty?
        errors << "scope #{key.inspect} must declare read_only" if supports_read_only && ![ true, false ].include?(scope["read_only"])
      end
      errors
    end
  end
end
