module Admin
  # Builds the config schema + current values response for a single plugin.
  # Used by the dedicated GET /plugins/:name/config endpoint and included
  # inline in the full PluginsPayload list.
  #
  # For :secret_env entries the value is never read from the DB; the response
  # returns { "present" => bool } based on whether the declared env var is set.
  # All other types return the stored value from PluginRecord#config["settings"],
  # falling back to the schema's :default when no value has been saved yet.
  class PluginConfigPayload
    def initialize(manifest, record)
      @manifest = manifest
      @record = record
    end

    def as_json(*)
      {
        config_schema: schema_payload,
        config: config_values
      }
    end

    private

    def schema_payload
      Array(@manifest&.config_schema).map { |entry| entry.transform_keys(&:to_s) }
    end

    def config_values
      schema = Array(@manifest&.config_schema)
      settings = @record&.config.to_h.dig("settings") || {}

      schema.each_with_object({}) do |entry, values|
        key = entry[:key].to_s
        if entry[:type].to_s == "secret_env"
          values[key] = { "present" => ENV[entry[:env_var].to_s].present? }
        else
          values[key] = settings.key?(key) ? settings[key] : entry[:default]
        end
      end
    end
  end
end
