# Plugin-contributed slices of the chat payload (see
# Syrus::Plugin::ChatPayloadContributor).
module ChatPayloadContributions
  class KeyConflict < StandardError; end

  def self.providers
    Syrus::Plugin::ChatIntegration.contributions(:payload_contributors)
  end

  def self.payload(chat_session:, context:, existing_keys:)
    merge_each(existing_keys) do |provider|
      invoke(provider, :chat_payload, {}) do
        provider.chat_payload(chat_session: chat_session, context: context)
      end
    end
  end

  def self.paths(chat_session:, existing_keys:)
    merge_each(existing_keys) { |provider| invoke(provider, :chat_payload_paths, {}) { provider.chat_payload_paths(chat_session: chat_session) } }
  end

  def self.counts(chat_session:, context:, existing_keys:)
    merge_each(existing_keys) { |provider| invoke(provider, :chat_payload_counts, {}) { provider.chat_payload_counts(chat_session: chat_session, context: context) } }
  end

  def self.message_payload(messages:, payloads:)
    providers.reduce(payloads) do |decorated, provider|
      invoke(provider, :chat_message_payload, decorated) do
        provider.chat_message_payload(messages: messages, payloads: decorated)
      end
    end
  end

  # A contributor silently overwriting a core key would be a bug nobody sees
  # until the page renders wrong, so it is an error instead.
  def self.merge_each(existing_keys)
    taken = existing_keys.map(&:to_sym).to_set

    providers.each_with_object({}) do |provider, merged|
      contribution = (yield provider).to_h.symbolize_keys

      contribution.each_key do |key|
        next unless taken.include?(key)

        raise KeyConflict, "#{provider} contributes #{key.inspect}, which is already in the chat payload"
      end

      taken.merge(contribution.keys)
      merged.merge!(contribution)
    end
  end

  def self.invoke(provider, operation, decline, &block)
    Syrus::PluginInvocation.value(Syrus::PluginInvocation.call(
      extension_point: :chat_payload_contributor, provider:, operation:, on_decline: decline, &block
    ))
  end
  private_class_method :invoke
end
