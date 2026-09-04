# Plugin-contributed slices of the chat payload (see
# Syrus::Plugin::ChatPayloadContributor).
module ChatPayloadContributions
  class KeyConflict < StandardError; end

  def self.providers
    Syrus::PluginRegistry.providers_for(:chat_payload_contributor)
  end

  def self.payload(chat_session:, context:, existing_keys:)
    merge_each(existing_keys) do |provider|
      PerformanceLogging.plugin_call(extension_point: :chat_payload_contributor, provider: provider, operation: :chat_payload) do
        provider.chat_payload(chat_session: chat_session, context: context)
      end
    end
  end

  def self.paths(chat_session:, existing_keys:)
    merge_each(existing_keys) { |provider| provider.chat_payload_paths(chat_session: chat_session) }
  end

  def self.counts(chat_session:, existing_keys:)
    merge_each(existing_keys) { |provider| provider.chat_payload_counts(chat_session: chat_session) }
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
end
