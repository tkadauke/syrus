class ChatIdentityContributions
  ContractError = Class.new(ArgumentError)

  class << self
    def identities(chat_session:, user:)
      providers.flat_map do |provider|
        invoke(provider, :chat_identities, []) { Array(provider.chat_identities(chat_session:, user:)) }
          .map { |identity| normalize_identity(identity, provider:) }
      end
    end

    def turn_identity(chat_session:, message:)
      providers.each do |provider|
        identity = invoke(provider, :chat_turn_identity, nil) { provider.chat_turn_identity(chat_session:, message:) }
        return normalize_identity(identity, provider:) if identity
      end
      nil
    end

    def trigger_decision(chat_session:, message:, mentions:)
      providers.each do |provider|
        decision = invoke(provider, :chat_turn_trigger, nil) { provider.chat_turn_trigger(chat_session:, message:, mentions:) }
        return normalize_trigger_decision(decision, provider:) if decision
      end
      nil
    end

    def search_ownership(user:)
      collect_unique(:chat_search_ownership, user:)
    end

    def group_ownership(user:)
      collect_unique(:chat_group_ownership, user:)
    end

    def message_presentations(messages:)
      merge_indexed(:chat_message_presentations, Array(messages), messages:)
    end

    def status_contributions(chat_sessions:, user:)
      merge_indexed(:chat_status_contributions, Array(chat_sessions), chat_sessions:, user:)
    end

    private

    def providers
      Syrus::Plugin::ChatIntegration.contributions(:identity_providers)
    end

    def invoke(provider, operation, decline, &block)
      Syrus::PluginInvocation.value(Syrus::PluginInvocation.call(
        extension_point: :chat_identity_provider, provider:, operation:, on_decline: decline, &block
      ))
    end

    def normalize_identity(identity, provider:)
      value = hash(identity, provider:, surface: "identity")
      required_strings!(value, %w[provider kind id], provider:, surface: "identity")
      snapshot = hash(value["snapshot"], provider:, surface: "identity snapshot")
      required_strings!(snapshot, %w[label], provider:, surface: "identity snapshot")
      deep_freeze(value.merge(
        "provider" => value.fetch("provider").to_s,
        "kind" => value.fetch("kind").to_s,
        "id" => value.fetch("id").to_s,
        "snapshot" => snapshot
      ))
    end

    def normalize_trigger_decision(decision, provider:)
      value = hash(decision, provider:, surface: "trigger decision")
      unless value["trigger"].in?([ true, false ])
        invalid!(provider, "trigger decision must contain boolean trigger")
      end
      required_strings!(value, %w[reason], provider:, surface: "trigger decision")
      deep_freeze(value)
    end

    def collect_unique(method, **kwargs)
      seen = {}
      providers.filter_map do |provider|
        contribution = invoke(provider, method, nil) { provider.public_send(method, **kwargs) }
        next unless contribution

        value = hash(contribution, provider:, surface: method)
        key = value.fetch("key") { invalid!(provider, "#{method} must contain key") }.to_s
        invalid!(provider, "#{method} key must not be blank") if key.blank?
        invalid!(provider, "duplicate #{method} key #{key.inspect}") if seen.key?(key)

        seen[key] = true
        deep_freeze(value.merge("key" => key))
      end
    end

    def merge_indexed(method, records, **kwargs)
      allowed_ids = records.to_h { |record| [ record.id.to_i, true ] }
      providers.each_with_object({}) do |provider, merged|
        value = hash(invoke(provider, method, {}) { provider.public_send(method, **kwargs) }, provider:, surface: method)
        value.each do |record_id, contribution|
          id = Integer(record_id, exception: false)
          invalid!(provider, "#{method} returned an unknown id") unless id && allowed_ids[id]
          invalid!(provider, "duplicate #{method} contribution for id #{id}") if merged.key?(id)

          merged[id] = deep_freeze(hash(contribution, provider:, surface: method))
        end
      end.freeze
    end

    def hash(value, provider:, surface:)
      invalid!(provider, "#{surface} must be a hash") unless value.respond_to?(:to_h)
      value.to_h.deep_stringify_keys
    end

    def required_strings!(value, keys, provider:, surface:)
      keys.each do |key|
        invalid!(provider, "#{surface} must contain non-blank #{key}") if value[key].to_s.blank?
      end
    end

    def invalid!(provider, message)
      raise ContractError, "#{provider} #{message}"
    end

    def deep_freeze(value)
      case value
      when Hash then value.to_h { |key, item| [ deep_freeze(key), deep_freeze(item) ] }.freeze
      when Array then value.map { |item| deep_freeze(item) }.freeze
      else value.freeze
      end
    end
  end
end
