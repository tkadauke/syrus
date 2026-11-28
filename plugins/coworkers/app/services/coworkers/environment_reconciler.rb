# Repairs Coworkers projections from authoritative build and image records.
# Each environment is locked independently so one bad record cannot prevent
# the remaining coworkers from being reconciled.
class Coworkers::EnvironmentReconciler
  STALE_BUILD_AFTER = 2.hours
  TERMINAL_REVISION_STATES = %w[revoked rejected build_failed].freeze
  Finding = Data.define(:environment_id, :revision_id, :kind, :detail)

  attr_reader :findings

  def initialize(now: Time.current)
    @now = now
    @findings = []
  end

  def call
    Coworkers::Environment.includes(revisions: [ :build_request, :runtime_image ]).find_each do |environment|
      reconcile_environment(environment)
    rescue StandardError => e
      add(environment, nil, :failed, "#{e.class.name}: #{e.message}")
      Rails.logger.warn("[Coworkers::EnvironmentReconciler] environment=#{environment.id} #{e.class}: #{e.message}")
    end
    findings
  end

  private

  def reconcile_environment(environment)
    lifecycle = Coworkers::EnvironmentLifecycle.new(environment, now: @now)
    environment.revisions.each do |revision|
      reconcile_revision(environment, revision, lifecycle)
    end
  end

  def reconcile_revision(environment, revision, lifecycle)
    if revision.building? || revision.verifying?
      request = revision.build_request
      if request&.terminal? || request&.verifying?
        lifecycle.reconcile_build!(revision)
        add(environment, revision, :build_projected, request.state)
      elsif request.nil? || stale?(request)
        lifecycle.reject!(revision, code: request ? "stale_build" : "missing_build_request")
        add(environment, revision, :stale_build, request ? request.state : "missing")
      end
    end

    image = revision.reload.runtime_image
    return unless image
    # Terminal revisions cannot move to revoked, so revoking them again on
    # every tick would only re-audit, re-publish, and overwrite the
    # environment's error code with an old revision's image state.
    return if TERMINAL_REVISION_STATES.include?(revision.state)
    if image.revoked? || image.deleted?
      lifecycle.revoke!(revision, reason: revocation_reason(image), severity: revocation_severity(image))
      add(environment, revision, :image_unavailable, image.availability)
    end
  end

  def revocation_reason(image)
    revocation_details(image).fetch("reason", nil).presence || "image_#{image.availability}"
  end

  def revocation_severity(image)
    revocation_details(image).fetch("severity", nil) == "severe" ? :severe : :normal
  end

  def revocation_details(image) = Syrus::Host::RuntimeImages.revocation_details(image)

  def stale?(request)
    request.updated_at < @now - STALE_BUILD_AFTER && !request.queued?
  end

  def add(environment, revision, kind, detail)
    findings << Finding.new(environment_id: environment.id, revision_id: revision&.id, kind: kind, detail: detail)
  end
end
