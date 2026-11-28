module Coworkers
  class Subscribers
    include Syrus::Host::DomainSubscriber

    def self.subscriptions
      { "runtime_image.rebuild_requested" => :request_environment_rebuild }.merge(
        %w[build_requested candidate build_failed rejected approval_required approval_denied activated rolled_back incompatible revoked]
          .to_h { |kind| [ "coworker_environment.#{kind}", :deliver_environment_event ] }
      )
    end

    def self.deliver_environment_event(event)
      payload = event.payload.to_h.deep_stringify_keys
      coworker = Coworkers::Coworker.find(payload.fetch("coworker_id"))
      chat = coworker.coworker_chats.find_by!(role: "main").chat_session
      content = {
        "text" => environment_event_text(event.name),
        "source" => "coworker_environment",
        "coworker_environment_event" => payload.merge("type" => event.name.delete_prefix("coworker_environment."))
      }
      chat.messages.create!(role: "system", content:, skip_turn_trigger: true)
    end

    def self.environment_event_text(name)
      I18n.t("api.coworkers.environment_events.#{name.delete_prefix('coworker_environment.')}")
    end

    def self.request_environment_rebuild(event)
      EnvironmentCompatibilityRebuild.new(
        runtime_image_id: event.payload.fetch("runtime_image_id"),
        replacement_base_release_id: event.payload.fetch("replacement_base_release_id"),
        reasons: event.payload.fetch("reasons")
      ).call
    end
  end
end
