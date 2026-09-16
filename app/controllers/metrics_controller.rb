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
    sync_plugin_declarations
    refresh_global_gauges
    render plain: Syrus::Metrics.render, content_type: Syrus::Metrics::TextFormat::CONTENT_TYPE
  end

  private

  # A plugin's `metrics do ... end` block declares through a `while_enabled`
  # effect (Syrus::Installer), which is sync-on-read like every other
  # Installer-backed registry (Filters::Registry.subjects, SmartFolder.
  # registered_subjects, CredentialProbe's registries) -- nothing re-applies
  # it on a timer. This is the metrics endpoint's own read path, so it syncs
  # before rendering: otherwise a plugin enabled or disabled since this
  # process's last sync would render a stale metric set (present-but-should-
  # be-gone, or declared-but-missing) until something else happened to sync.
  def sync_plugin_declarations
    Syrus::Installer.sync!
  rescue StandardError => e
    Rails.logger.warn("[MetricsController] plugin declaration sync failed: #{e.class}: #{e.message}")
  end

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
  #
  # Iterates Syrus::Metrics.samplers rather than a hardcoded list -- the same
  # registry SampleGlobalMetricsJob samples into. Adding a new core or plugin
  # sampler requires no change here; each sampler's refresh is independently
  # rescued so one unreachable source costs its own gauges, not the scrape.
  def refresh_global_gauges
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return if self.class.last_refresh_at && (now - self.class.last_refresh_at) < REFRESH_WINDOW

    Syrus::Metrics.samplers.each do |sampler|
      sampler.refresh_gauges!
    rescue StandardError => e
      Rails.logger.warn("[MetricsController] could not refresh #{sampler}: #{e.class}: #{e.message}")
    end
    refresh_plugin_gauges
    self.class.last_refresh_at = now
  rescue StandardError => e
    Rails.logger.warn("[MetricsController] could not refresh global gauges: #{e.class}: #{e.message}")
  end

  # Core cannot name a plugin's sampler directly -- that would make the
  # plugin undeletable (see CLAUDE.md, "Core specs must not enumerate
  # plugin-provided things") -- so this asks every enabled, healthy plugin's
  # callbacks provider instead. Most leave `on_metrics_scrape` at its default
  # no-op; a plugin sampling a global metric on its own tick overrides it.
  # One plugin's failure must not blank every other plugin's metrics.
  def refresh_plugin_gauges
    Syrus::PluginRegistry.providers_for(:callbacks).each do |provider|
      provider.on_metrics_scrape
    rescue StandardError => e
      Rails.logger.warn("[MetricsController] plugin metrics refresh failed for #{provider}: #{e.class}: #{e.message}")
    end
  end

  class << self
    attr_accessor :last_refresh_at
  end
end
