module Syrus
  # Reads a plugin's operator-configured settings back at runtime.
  #
  # config_schema rendered an admin form and wrote PluginRecord#config["settings"],
  # but nothing ever read it, so a plugin needing configuration had to reach for
  # ENV directly and its schema entry was decoration. This is the read side.
  #
  # Resolution, per schema entry:
  #
  #   type: :secret_env  ENV[env_var] only. The value is never stored in or read
  #                      from the database, so an operator cannot exfiltrate a
  #                      secret through the settings API.
  #   otherwise          the stored value, else the schema's :default.
  #
  # A key not in the schema returns nil: the schema is the contract, so a typo
  # fails visibly at the call site instead of silently reading a stale value.
  class PluginSettings
    CACHE_TTL = Rails.env.test? ? 0.seconds : 5.seconds

    class << self
      def for(plugin_name)
        new(plugin_name.to_s)
      end

      def get(plugin_name, key)
        self.for(plugin_name).get(key)
      end
    end

    def initialize(plugin_name)
      @plugin_name = plugin_name
    end

    def get(key)
      entry = schema_entry(key)
      return nil if entry.nil?

      return ENV[entry[:env_var].to_s].presence if entry[:type].to_s == "secret_env"

      settings = stored_settings
      settings.key?(key.to_s) ? settings[key.to_s] : entry[:default]
    end

    alias_method :[], :get

    def present?(key)
      value = get(key)
      value.respond_to?(:empty?) ? !value.empty? : !value.nil?
    end

    def to_h
      Array(manifest&.config_schema).each_with_object({}) do |entry, values|
        values[entry[:key].to_s] = get(entry[:key])
      end
    end

    private

    attr_reader :plugin_name

    def schema_entry(key)
      Array(manifest&.config_schema).find { |entry| entry[:key].to_s == key.to_s }
    end

    def manifest
      Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == plugin_name }
    end

    def stored_settings
      record = PluginRecord.find_by(name: plugin_name)
      record&.config.to_h["settings"].to_h
    rescue ActiveRecord::ActiveRecordError
      {}
    end
  end
end
