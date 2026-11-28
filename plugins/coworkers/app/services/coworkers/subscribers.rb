module Coworkers
  class Subscribers
    include Syrus::Host::DomainSubscriber

    def self.subscriptions
      {
        "runtime_image.rebuild_requested" => :request_environment_rebuild,
        "coworker_base.revoked" => :on_base_revoked
      }
    end

    def self.request_environment_rebuild(event)
      EnvironmentCompatibilityRebuild.new(
        runtime_image_id: event.payload.fetch("runtime_image_id"),
        replacement_base_release_id: event.payload.fetch("replacement_base_release_id"),
        reasons: event.payload.fetch("reasons")
      ).call
    end

    # NY47: a severe base revocation means the base's bits are unsafe, and an
    # environment image built on it carries them. Each environment revision
    # built on the base is revoked severely, which clears its pointers and
    # terminates its turns. Turns on the base digest itself are terminated by
    # the base revocation (Service#revoke with the severity).
    def self.on_base_revoked(event)
      return unless event[:severity].to_s == "severe"

      reason = "coworker base revoked: #{event[:reason]}"
      Coworkers::EnvironmentRevision.where(coworker_base_release_id: event[:release_id])
                                    .where.not(runtime_image_id: nil)
                                    .includes(:environment, :runtime_image).find_each do |revision|
        revoke_derived!(revision, reason)
      end
    end

    def self.revoke_derived!(revision, reason)
      Coworkers::EnvironmentLifecycle.new(revision.environment)
                                     .revoke!(revision, reason: reason, actor: "system", severity: :severe)
    rescue StandardError => e
      # One environment failing to revoke must not leave the others running.
      Rails.logger.error("[Coworkers] severe base revocation of revision #{revision.id} failed: #{e.class}: #{e.message}")
    end
    private_class_method :revoke_derived!
  end
end
