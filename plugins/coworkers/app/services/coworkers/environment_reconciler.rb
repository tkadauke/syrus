class Coworkers::EnvironmentReconciler
  STALE_BUILD_AGE = 1.hour

  def initialize(lifecycle: Coworkers::EnvironmentLifecycle.new, now: Time.current)
    @lifecycle = lifecycle
    @now = now
  end

  def call
    Coworkers::EnvironmentRevision.includes(:build_request, :runtime_image, :environment).find_each do |revision|
      reconcile(revision)
    end
  end

  private

  def reconcile(revision)
    return reconcile_image(revision) if revision.runtime_image_id
    return unless revision.building?

    request = revision.build_request
    return unless request
    stale = revision.updated_at <= @now - STALE_BUILD_AGE && !request.current_attempt&.active?
    return unless request.terminal? || stale

    outcome_for(request).apply(@lifecycle, revision)
  end

  def reconcile_image(revision)
    image = revision.runtime_image
    return @lifecycle.deleted!(revision) unless image
    return @lifecycle.revoke!(revision, reason: image.revoked_reason.presence || "runtime_image_revoked") if image.revoked?
    return @lifecycle.deleted!(revision) if image.deleted?
    return unless revision.compat_min && revision.compat_max

    base = Syrus::Host::RuntimeImages.active_base(platform: image.platform)
    @lifecycle.incompatible!(revision) if base && !revision.compatible_with?(base.runtime_abi)
  end

  def outcome_for(request)
    BuildOutcome.for(request)
  end

  class BuildOutcome
    def self.for(request)
      { "succeeded" => Succeeded, "rejected" => Rejected, "failed" => Failed,
        "canceled" => Failed }.fetch(request.state, Stale).new(request)
    end

    def initialize(request) = @request = request
  end

  class Succeeded < BuildOutcome
    def apply(lifecycle, revision)
      image = @request.result&.runtime_image
      return lifecycle.deleted!(revision) unless image

      lifecycle.candidate!(revision, image)
      lifecycle.verified!(revision)
    end
  end

  class Rejected < BuildOutcome
    def apply(lifecycle, revision) = lifecycle.reject!(revision, code: @request.result&.error_code || "build_rejected")
  end

  class Failed < BuildOutcome
    def apply(lifecycle, revision) = lifecycle.build_failed!(revision, code: @request.result&.error_code || @request.state)
  end

  class Stale < BuildOutcome
    def apply(lifecycle, revision) = lifecycle.build_failed!(revision, code: "stale_build")
  end
end
