# Repairs Coworkers projections from authoritative build and image records.
# Each environment is locked independently so one bad record cannot prevent
# the remaining coworkers from being reconciled.
class Coworkers::EnvironmentReconciler
  STALE_BUILD_AFTER = 2.hours
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
    repair_activation_projection(environment)
  end

  # Activation history is the immutable publication evidence. If a crash or
  # partial operational repair left the convenience pointers out of sync,
  # restore them only from the still-launchable active activation. This repair
  # deliberately remains available while the product gate is disabled.
  def repair_activation_projection(environment)
    environment.with_lock do
      environment.reload
      activation = environment.active_activation
      return unless activation

      activation.reload
      image = activation.runtime_image.reload
      revision = activation.revision.reload
      return unless image.pullable? && activation.verification_attestation.valid_at?(@now)
      return unless activation.image_digest == image.digest && activation.source_digest == revision.source_digest

      expected = [ revision.id, image.id ]
      actual = [ environment.active_revision_id, environment.active_runtime_image_id ]
      return if actual == expected && environment.state == "active"

      environment.update!(state: "active", active_revision: revision, active_runtime_image: image,
                          last_error_code: nil)
      event = Syrus::Host::RuntimeImages.audit(
        "coworker_environment.projection_repaired", outcome: :repaired, image:, actor: "reconciler",
        details: { coworker_id: environment.coworker_id, environment_id: environment.id,
                   activation_id: activation.id, revision_id: revision.id }
      )
      environment.update!(last_audit_event: event) if event
      add(environment, revision, :activation_projection_repaired, "active pointers restored")
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
    if image.revoked? || image.deleted?
      lifecycle.revoke!(revision, reason: revocation_reason(image), severity: revocation_severity(image)) unless revision.revoked?
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
