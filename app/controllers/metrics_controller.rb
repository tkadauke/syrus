# Prometheus scrape endpoint.
#
# Token-gated with the same admin API token the rest of /api/v1/admin uses, so
# there is no new credential to manage. Deployments that would rather restrict
# this at the network layer (a NetworkPolicy admitting only the Prometheus pod)
# can set SYRUS_METRICS_PUBLIC=1 -- reasonable precisely because everything here
# is an aggregate with bounded labels, so there is nothing identifying to leak.
#
# The response is rendered from in-memory instrument state. Global gauges are
# refreshed from a cached sample first: one indexed key lookup, memoized for a
# short window so a scrape storm cannot become repeated reads. No aggregate
# query runs here -- an endpoint that queried the queue tables would get slow at
# exactly the moment those tables are the problem.
class MetricsController < Api::BaseController
  # The inherited authentication is replaced rather than conditionally skipped:
  # `skip_before_action ..., if:` is not a runtime condition in Rails, and
  # writing it that way silently let unauthenticated requests through.
  skip_before_action :authenticate_via_api_token
  before_action :authorize_scrape

  # Long enough that concurrent scrapes collapse onto one cache read, short
  # enough that it never hides a fresh sample from a 15s scrape interval.
  REFRESH_WINDOW = 5.seconds

  def show
    refresh_global_gauges
    render plain: Syrus::Metrics.render, content_type: Syrus::Metrics::TextFormat::CONTENT_TYPE
  end

  private

  def authorize_scrape
    return if public_metrics?

    # `authenticate_via_api_token` renders its own 401, but returns the render
    # result -- which is truthy -- so its return value cannot be used to tell
    # success from failure. `performed?` is the reliable question.
    authenticate_via_api_token
    return if performed?

    require_metrics_access
  end

  def public_metrics?
    ActiveModel::Type::Boolean.new.cast(ENV["SYRUS_METRICS_PUBLIC"]).present?
  end

  def require_metrics_access
    return if current_api_user&.admin?

    render_error("forbidden", I18n.t("api.base.admin_required"), status: :forbidden)
  end

  # Best-effort by design: a failure to refresh the global gauges must still
  # produce a scrape of everything else. Returning a 500 here would take the
  # per-process counters down with it, which is the opposite of what a
  # monitoring endpoint should do under stress.
  def refresh_global_gauges
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return if self.class.last_refresh_at && (now - self.class.last_refresh_at) < REFRESH_WINDOW

    Metrics::QueueSampler.refresh_gauges!
    self.class.last_refresh_at = now
  rescue StandardError => e
    Rails.logger.warn("[MetricsController] could not refresh global gauges: #{e.class}: #{e.message}")
  end

  class << self
    attr_accessor :last_refresh_at
  end
end
