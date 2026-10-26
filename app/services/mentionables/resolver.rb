module Mentionables
  class Resolver
    HANDLE_PATTERN = /(?<![a-z0-9_-])@(?<handle>[a-z0-9_-]{3,32})(?![a-z0-9_-])/i
    CORE_FINDERS = {
      "syrus" => ->(id) { Mentionables::Syrus.new if id.to_s == "syrus" },
      "human" => ->(id) { User.find_by(id: id) }
    }.freeze

    class << self
      def resolve(text:, chat:)
        candidates = candidates_for(chat)
        text.to_s.to_enum(:scan, HANDLE_PATTERN).filter_map do
          match = Regexp.last_match
          mentionable = candidates[match[:handle].downcase]
          next unless mentionable&.addressable_in?(chat)

          serialize(mentionable, match)
        end
      end

      def find(kind:, id:)
        core = find_core(kind: kind, id: id)
        return core if core

        ::Syrus::PluginRegistry.providers_for(:mentionable).filter_map do |provider|
          provider.find_mentionable(kind: kind, id: id)
        end.first
      end

      private

      def candidates_for(chat)
        participants = chat.association(:chat_participants)
        humans = if participants.loaded?
          participants.target.map(&:user)
        else
          chat.participants.to_a
        end
        core = [ Mentionables::Syrus.new, *humans ]
        plugin = ::Syrus::PluginRegistry.providers_for(:mentionable).flat_map do |provider|
          Array(provider.mentionables(chat: chat))
        end
        (core + plugin).index_by { |mentionable| mentionable.handle.to_s.downcase }
      end

      def find_core(kind:, id:)
        CORE_FINDERS[kind.to_s]&.call(id)
      end

      def serialize(mentionable, match)
        {
          "kind" => mentionable.kind,
          "id" => mentionable.mentionable_id,
          "handle" => mentionable.handle,
          "start" => match.begin(0),
          "end" => match.end(0)
        }
      end
    end
  end
end
