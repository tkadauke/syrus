module Coworkers
  class ChatIdentityProvider
    include Syrus::Plugin::ChatIdentityProvider

    class << self
      def chat_identities(chat_session:, user:)
        identities = Coworkers::Chat.where(chat_session_id: chat_session.id)
          .includes(coworker: { avatar_attachment: :blob }).filter_map do |link|
          next unless link.coworker.owner_user_id == user.id

          identity(link.coworker, role: link.role)
        end
        roster = Coworkers::ChatAgent.where(chat_session_id: chat_session.id)
          .includes(coworker: { avatar_attachment: :blob }).filter_map do |entry|
          next unless entry.coworker.owner_user_id == user.id

          identity(entry.coworker, role: "roster")
        end
        identities + roster
      end

      def chat_turn_identity(chat_session:, message:)
        coworker = rostered_coworker(chat_session, message) || linked_coworker(chat_session)
        identity(coworker) if coworker
      end

      # Coworker-owned turns preserve the host invariant exactly: a direct
      # chat speaks automatically, while a multi-human chat requires an
      # explicit mention of an addressable agent. Returning nil for all other
      # chats leaves the generic host policy in charge.
      def chat_turn_trigger(chat_session:, message:, mentions:)
        owns_turn = linked_coworker(chat_session) || coworker_mentions(mentions).any?
        return unless owns_turn

        trigger = chat_session.chat_participants.count <= 1 || Array(mentions).any? do |mention|
          mentionable = Mentionables::Resolver.find(kind: mention["kind"], id: mention["id"])
          mentionable&.agentic? && mentionable.addressable_in?(chat_session)
        end
        { trigger: trigger, reason: trigger ? "addressed coworker turn" : "unaddressed group turn" }
      end

      def chat_search_ownership(user:)
        { key: "coworkers", filter_field: "coworker_id" }
      end

      def chat_group_ownership(user:)
        links = Coworkers::Chat.includes(coworker: { avatar_attachment: :blob })
          .joins(:coworker).where(coworkers: { owner_user_id: user.id })
        metadata = links.index_with do |link|
          { agent_appearance: appearance(link.coworker) }
        end.transform_keys(&:chat_session_id)
        {
          key: "coworkers",
          label: I18n.t("api.coworkers.chat_group"),
          chat_session_ids: metadata.keys,
          metadata_by_chat_session_id: metadata
        }
      end

      def chat_message_presentations(messages:)
        Coworkers::PayloadContributor.message_presentations(messages: messages)
      end

      def chat_status_contributions(chat_sessions:, user:)
        links = Coworkers::Chat.where(chat_session_id: chat_sessions.map(&:id))
          .includes(coworker: { avatar_attachment: :blob })
        links.to_h do |link|
          [ link.chat_session_id, { identity: identity(link.coworker, role: link.role) } ]
        end
      end

      private

      def linked_coworker(chat_session)
        Coworkers::Chat.includes(:coworker).find_by(chat_session_id: chat_session.id)&.coworker
      end

      def rostered_coworker(chat_session, message)
        ids = coworker_mentions(message&.resolved_mentions)
        return if ids.empty?

        roster = Coworkers::ChatAgent.where(chat_session_id: chat_session.id, coworker_id: ids)
          .includes(:coworker).index_by(&:coworker_id)
        ids.lazy.filter_map { |id| roster[id]&.coworker }.first
      end

      def coworker_mentions(mentions)
        Array(mentions).filter_map { |mention| mention["id"].to_i if mention["kind"] == "coworker" }
      end

      def identity(coworker, role: nil)
        {
          provider: "coworkers", kind: "coworker", id: coworker.id,
          role: role,
          snapshot: appearance(coworker).merge(label: coworker.name)
        }.compact
      end

      def appearance(coworker)
        {
          name: coworker.name, handle: coworker.handle,
          accent_hex: coworker.accent_hex, avatar_key: coworker.avatar_key,
          avatar_url: coworker.avatar_url
        }
      end
    end
  end
end
