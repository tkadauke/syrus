module Mentionables
  class Suggestions
    LIMIT = 20

    def self.for(chat:, user:, query: nil) = new(chat: chat, user: user, query: query).call

    def initialize(chat:, user:, query: nil)
      @chat = chat
      @user = user
      @query = query.to_s.delete_prefix("@").downcase.strip
    end

    def call
      seen = {}
      ordered = addressable_candidates.map { |candidate| [ candidate, false ] }
      ordered.concat(additional_candidates.map { |candidate| [ candidate, true ] })
      ordered << [ Mentionables::Syrus.new, false ]

      ordered.filter_map do |candidate, add_to_chat|
        key = [ candidate.kind, candidate.mentionable_id.to_s ]
        next if seen[key] || !matches?(candidate)

        seen[key] = true
        serialize(candidate, add_to_chat: add_to_chat)
      end.first(LIMIT)
    end

    private

    def addressable_candidates
      participants = @chat.chat_participants.includes(user: :handle_record).order(:joined_at, :id).map(&:user)
      participants + providers.flat_map { |provider| Array(provider.mentionables(chat: @chat)) }
    end

    def additional_candidates
      providers.flat_map do |provider|
        next [] unless provider.respond_to?(:autocomplete_mentionables)

        Array(provider.autocomplete_mentionables(chat: @chat, user: @user))
      end
    end

    def providers = ::Syrus::PluginRegistry.providers_for(:mentionable)

    def matches?(candidate)
      return true if @query.blank?

      [ candidate.handle, candidate.display_name, candidate.subtitle ].compact.any? { |value| value.to_s.downcase.include?(@query) }
    end

    def serialize(candidate, add_to_chat:)
      {
        id: candidate.mentionable_id, handle: candidate.handle, display_name: candidate.display_name,
        subtitle: candidate.subtitle, kind: candidate.kind, avatar_url: candidate.avatar_url,
        avatar_key: candidate.avatar_key, color_key: candidate.color_key, add_to_chat: add_to_chat
      }
    end
  end
end
