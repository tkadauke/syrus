require "json"

class PluginRepositoryConfiguration
  KEY_PATTERN = /\A[a-z][a-z0-9_]*\.[a-z][a-z0-9_.-]*\z/
  # Retained while legacy top-level keys migrate to namespaced envelopes. It
  # lets core explain an orphaned key even when the owning plugin is removed.
  LEGACY_OWNERS = { "coworker_review" => "coworkers" }.freeze
  Diagnostic = Data.define(:key, :owner, :status, :message) do
    def to_h = { "key" => key, "owner" => owner, "status" => status, "message" => message }
  end

  Contribution = Data.define(:key, :owner, :schema_version, :value, :serialized, :provider) do
    def to_h
      { "key" => key, "owner" => owner, "schema_version" => schema_version, "config" => serialized }
    end
  end

  class Set
    attr_reader :diagnostics

    def initialize(contributions: {}, diagnostics: [])
      @contributions = contributions.sort.to_h.freeze
      @diagnostics = diagnostics.sort_by { |item| [ item.key, item.status, item.message ] }.freeze
      freeze
    end

    def [](key) = @contributions[key.to_s]&.value
    def contribution(key) = @contributions[key.to_s]
    def keys = @contributions.keys
    def empty? = @contributions.empty?
    def to_h = @contributions.transform_values(&:to_h)

    def overlay(project)
      keys = (@contributions.keys | project.send(:contributions).keys).sort
      merged = keys.to_h do |key|
        root_entry = @contributions[key]
        project_entry = project.send(:contributions)[key]
        provider = project_entry&.provider || root_entry&.provider
        value = if root_entry && project_entry
          provider.overlay(root: root_entry.value, project: project_entry.value)
        else
          (project_entry || root_entry).value
        end
        [ key, PluginRepositoryConfiguration.build_contribution(provider, value, owner: (project_entry || root_entry).owner) ]
      end
      self.class.new(contributions: merged, diagnostics: diagnostics + project.diagnostics)
    end

    def affected?(key, project:, changed_files:)
      entry = @contributions[key.to_s]
      entry && entry.provider.affected_project?(
        configuration: entry.value, project: project, changed_files: Array(changed_files)
      )
    end

    protected

    attr_reader :contributions
  end

  Registration = Data.define(:owner, :provider, :status)

  class << self
    def parse(raw, scope:)
      registrations = registrations_by_key
      contributions = {}
      diagnostics = []

      parse_namespaced(raw["plugins"], scope:, registrations:, contributions:, diagnostics:)
      parse_legacy(raw, scope:, registrations:, contributions:, diagnostics:)
      declared_legacy_keys = registrations.values.flat_map { |entry| Array(entry.provider.legacy_keys).map(&:to_s) }.to_set
      LEGACY_OWNERS.each do |key, owner|
        next unless raw.key?(key) && !declared_legacy_keys.include?(key)

        diagnostics << Diagnostic.new(
          key:, owner:, status: "absent", message: "#{key} belongs to absent plugin #{owner.inspect}"
        )
      end
      Set.new(contributions:, diagnostics:)
    end

    def build_contribution(provider, value, owner: nil)
      serialized = canonical_json(provider.serialize(value: value))
      Contribution.new(
        key: provider.key.to_s,
        owner: owner || provider.key.to_s.split(".", 2).first,
        schema_version: Integer(provider.schema_version),
        value: value,
        serialized: deep_freeze(serialized),
        provider: provider
      )
    rescue JSON::GeneratorError, TypeError => e
      raise SyrusYml::ParseError, "plugins.#{provider.key}: unsafe serialization: #{e.message}"
    end

    private

    def canonical_json(value)
      normalized = JSON.parse(JSON.generate(value))
      case normalized
      when Hash
        normalized.keys.sort.to_h { |key| [ key, canonical_json(normalized[key]) ] }
      when Array
        normalized.map { |item| canonical_json(item) }
      else
        normalized
      end
    end

    def deep_freeze(value)
      value.each { |key, item| deep_freeze(key); deep_freeze(item) } if value.is_a?(Hash)
      value.each { |item| deep_freeze(item) } if value.is_a?(Array)
      value.freeze
    end

    def registrations_by_key
      manifests = Syrus::PluginRegistry.all_plugins
      health = Syrus::PluginRegistry.health
      registrations = manifests.flat_map do |manifest|
        Array(manifest.provides[:repository_configuration]).map do |provider|
          status = if !manifest.enabled?
            "disabled"
          elsif health.healthy?(manifest.name)
            "enabled"
          else
            "unavailable"
          end
          Registration.new(owner: manifest.name, provider: provider, status: status)
        end
      end
      registrations.concat(Syrus::PluginRegistry.direct_providers_for(:repository_configuration).map do |provider|
        Registration.new(owner: provider.key.to_s.split(".", 2).first, provider: provider, status: "enabled")
      end)
      registrations.sort_by { |entry| [ entry.provider.key.to_s, entry.owner ] }.each_with_object({}) do |entry, result|
        key = entry.provider.key.to_s
        raise SyrusYml::ParseError, "repository configuration key #{key.inspect} must be namespaced" unless key.match?(KEY_PATTERN)
        unless key.start_with?("#{entry.owner}.")
          raise SyrusYml::ParseError,
            "repository configuration key #{key.inspect} must use owner namespace #{entry.owner.inspect}"
        end
        raise SyrusYml::ParseError, "repository configuration key #{key.inspect} is registered more than once" if result.key?(key)

        result[key] = entry
      end
    end

    def parse_namespaced(raw, scope:, registrations:, contributions:, diagnostics:)
      return if raw.nil?
      raise SyrusYml::ParseError, "plugins: must be a mapping" unless raw.is_a?(Hash)

      raw.deep_stringify_keys.sort.each do |key, envelope|
        raise SyrusYml::ParseError, "plugins key #{key.inspect} must be namespaced" unless key.match?(KEY_PATTERN)
        registration = registrations[key]
        unless registration
          owner = key.split(".", 2).first
          diagnostics << Diagnostic.new(key:, owner:, status: "absent", message: "configuration provider #{owner.inspect} is not installed")
          next
        end
        unless registration.status == "enabled"
          diagnostics << Diagnostic.new(key:, owner: registration.owner, status: registration.status, message: "configuration provider #{registration.owner.inspect} is #{registration.status}")
          next
        end
        raise SyrusYml::ParseError, "plugins.#{key}: must be a mapping" unless envelope.is_a?(Hash)
        envelope = envelope.deep_stringify_keys
        version = envelope["version"]
        raise SyrusYml::ParseError, "plugins.#{key}.version: is required" if version.nil?
        raise SyrusYml::ParseError, "plugins.#{key}.version: must be an integer" unless version.is_a?(Integer)
        value = registration.provider.parse(value: envelope["config"], version: version, scope: scope)
        contributions[key] = build_contribution(registration.provider, value, owner: registration.owner)
      rescue ArgumentError => e
        raise SyrusYml::ParseError, "plugins.#{key}: #{e.message}"
      end
    end

    def parse_legacy(raw, scope:, registrations:, contributions:, diagnostics:)
      registrations.values.each do |registration|
        Array(registration.provider.legacy_keys).map(&:to_s).sort.each do |legacy_key|
          next unless raw.key?(legacy_key)
          if registration.status == "enabled"
            value = registration.provider.parse(value: raw[legacy_key], version: registration.provider.schema_version, scope: scope)
            contributions[registration.provider.key.to_s] ||= build_contribution(
              registration.provider, value, owner: registration.owner
            )
          else
            diagnostics << Diagnostic.new(
              key: legacy_key, owner: registration.owner, status: registration.status,
              message: "#{legacy_key} belongs to #{registration.status} plugin #{registration.owner.inspect}"
            )
          end
        rescue ArgumentError => e
          raise SyrusYml::ParseError, "#{legacy_key}: #{e.message}"
        end
      end
    end
  end
end
