# After a coworker base is promoted, rolled back, revoked, or has its support
# window changed, finds the environments that now need a rebuild and records
# the result for operators. Also repairs releases whose image was revoked or
# deleted by something other than the release lifecycle.
class BaseRebuildDiscoveryJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    RuntimeImages::BaseReleases.new.sync_with_images!
    compatibility = RuntimeImages::BaseCompatibility.new
    findings = compatibility.environments_needing_rebuild
    summary = compatibility.summary(findings: findings)
    findings.each do |finding|
      next unless finding.replacement

      Syrus::Events.publish("runtime_image.rebuild_requested",
                            runtime_image_id: finding.image.id,
                            replacement_base_release_id: finding.replacement.id,
                            reasons: finding.reasons)
    end
    if summary[:total].positive?
      RuntimeImages::Audit.record("base_release.rebuild_needed", outcome: :detected, actor: "system",
                                  details: { total: summary[:total], blocked: summary[:blocked], by_reason: summary[:by_reason].to_json })
    end
    Rails.logger.info("[BaseRebuildDiscoveryJob] needing_rebuild=#{summary[:total]} blocked=#{summary[:blocked]}")
    summary[:total]
  end
end
