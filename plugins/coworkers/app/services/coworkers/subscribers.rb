module Coworkers
  class Subscribers
    include Syrus::Plugin::DomainSubscriber

    def self.subscriptions
      { "runtime_image.rebuild_requested" => :request_environment_rebuild }
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
