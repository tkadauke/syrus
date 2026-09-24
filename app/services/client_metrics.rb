# Turns a small, closed set of frontend-observed events into real Prometheus
# counters. Several of the signals worth measuring --
# an entity-store patch actually landing, a revision-gap recovery firing, a
# hidden tab suppressing a fetch -- only happen in the browser, and this
# metrics library has no way to reach into a browser process. This is the
# one narrow bridge: app/frontend/lib/clientMetrics.ts batches increments and
# posts them to Api::V1::App::ClientMetricsController, which calls #record.
#
# Both `name` and `resource` are closed enums, not free strings, for the same
# reason Metrics::ProductUsage's FEATURES is closed: this is a public,
# authenticated HTTP boundary, so an unrecognized value is silently dropped
# in every environment rather than raised -- unlike ProductUsage, which is
# only ever called from trusted server-side code and can afford to raise in
# development/test. `by` is clamped so a single misbehaving tab cannot skew
# a counter by an implausible amount in one request.
module ClientMetrics
  REPORTABLE = {
    "entity_patch_applications" => :syrus_client_entity_patch_applications_total,
    "revision_gap_recoveries" => :syrus_client_revision_gap_recoveries_total,
    "hidden_tab_suppressed_fetches" => :syrus_client_hidden_tab_suppressed_fetches_total
  }.freeze

  RESOURCES = %w[job workflow step run chat dashboard epic repository notification unknown].freeze
  VISIBILITY_STATES = %w[visible hidden unknown].freeze
  MAX_BY = 1_000

  def self.declare_metrics!
    Syrus::Metrics.declare do
      counter :client_entity_patch_applications_total, tags: %i[resource visibility_state],
              comment: "Browser entity-store patches applied directly from an application event, by resource and " \
                       "the tab's visibility state when it applied -- reported by the frontend"
      counter :client_revision_gap_recoveries_total, tags: %i[resource],
              comment: "Browser-detected application-event sequence gaps recovered with a targeted refetch, by " \
                       "resource -- reported by the frontend"
      counter :client_hidden_tab_suppressed_fetches_total, tags: %i[resource],
              comment: "Refetches a hidden browser tab deferred instead of running immediately, by resource -- " \
                       "reported by the frontend"
    end
  end
  declare_metrics!

  def self.record(name:, resource: nil, visibility_state: nil, by: 1)
    metric = REPORTABLE[name.to_s]
    return unless metric

    tags = { resource: RESOURCES.include?(resource.to_s) ? resource.to_s : "unknown" }
    tags[:visibility_state] = VISIBILITY_STATES.include?(visibility_state.to_s) ? visibility_state.to_s : "unknown" if name.to_s == "entity_patch_applications"
    Syrus::Metrics.counter(metric).increment(tags: tags, by: clamp_by(by))
  end

  def self.clamp_by(by)
    Integer(by).clamp(1, MAX_BY)
  rescue ArgumentError, TypeError
    1
  end
  private_class_method :clamp_by
end
