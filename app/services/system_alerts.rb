# Surface "something is broken right now, here's what to do about it"
# banners at the top of every authenticated page. Designed for many
# alert sources to compose into one rendering path:
#
#   * per-user computed (GitHub token blocked, Claude OAuth missing)
#   * global computed (polling paused, runs paused via AppSetting)
#   * future: stored alerts (a `system_alerts` table) for things
#     that should persist across pod restarts and need explicit
#     dismissal.
#
# Add a new alert source by writing a private method here that
# returns a `SystemAlerts::Alert` (or nil) and calling it from
# `.active_for`. The React shell owns rendering for app pages.
module SystemAlerts
  # Severity drives color in the banner partial:
  #   :alarm — red, "this is broken right now"
  #   :warn  — amber, "this is degraded but limping"
  #   :info  — blue, "you should know about this"
  SEVERITIES = %i[ alarm warn info ].freeze

  Alert = Data.define(:id, :dismissal_key, :severity, :title, :message, :action_steps, :cta, :actions) do
    def initialize(id:, severity:, title:, message:, action_steps:, dismissal_key: id, cta: nil, actions: [])
      super(id: id, dismissal_key: dismissal_key, severity: severity, title: title, message: message, action_steps: action_steps, cta: cta, actions: actions)
    end
  end

  def self.active_for(user:)
    out = []
    out << github_token_blocked(user) if user&.gh_api_blocked?
    out << codex_usage(user) if user
    out << data_root_disk_usage if user&.admin?
    out
      .compact
      .sort_by { |alert| SEVERITIES.index(alert.severity) || SEVERITIES.length }
  end

  def self.github_token_blocked(user)
    # The `gh_api_blocked_reason` is verbatim text from GitHub's API
    # response (Octokit error message). Treat as untrusted — escape
    # before wrapping in <code> so anything weird in the body can't
    # break the page.
    reason = ERB::Util.html_escape(user.gh_api_blocked_reason.to_s)
    Alert.new(
      id: "github_token_scope:#{user.id}",
      dismissal_key: "github_token_scope:#{user.id}",
      severity: :alarm,
      title: "GitHub API access is blocked for this account.",
      message: "Syrus tried to read GitHub on your behalf and got back: " \
               "<code>#{reason}</code>. PR-feedback polling and " \
               "CI-failure detection are degraded until this is fixed; " \
               "the banner clears automatically on the next successful API call.",
      action_steps: [
        "Generate a <strong>classic</strong> PAT at " \
          "<a class=\"underline\" href=\"https://github.com/settings/tokens\">github.com/settings/tokens</a> " \
          "with the <code>repo</code> scope (which covers the entire Syrus surface — clone, push, PRs, comments, check-runs).",
        "Fine-grained PATs <em>do not work</em> for the full surface today: GitHub doesn't expose a <code>Checks: read</code> permission " \
          "for fine-grained tokens, so CI-failure detection silently breaks. If you want fine-grained anyway, accept that the " \
          "<code>check-runs</code> path will keep showing this banner.",
        "Paste the new token into <a class=\"underline\" href=\"/credentials\">Settings → Credentials</a> and save. " \
          "The banner clears on the next successful API call."
      ],
      cta: { text: "Update token", path: "/credentials" },
      actions: []
    )
  end
  private_class_method :github_token_blocked

  def self.codex_usage(user)
    availability = App::ProviderAvailability.for_user(user, "codex")
    status = availability&.dig(:usage, :status).to_s.presence || user.codex_usage_status.to_s
    latest_success_at = availability&.dig(:evidence, :latest_positive, :observed_at)&.then { |value| Time.zone.parse(value) rescue nil }
    stale_exhausted_cache = status == "exhausted" && latest_success_at && user.codex_usage_observed_at && latest_success_at > user.codex_usage_observed_at
    return unless availability&.dig(:usage_exhausted) || status == "warning" || (status == "exhausted" && !stale_exhausted_cache)

    snapshot = user.codex_usage_snapshot || {}
    remaining = snapshot["remaining_percent"]
    limit_label = codex_usage_breakdown(snapshot).presence || (remaining.present? ? "#{remaining.round}% remaining" : status)
    reset_at = codex_usage_reset_at(snapshot, status: status)
    exhausted = availability&.dig(:usage_exhausted) || status == "exhausted"
    title = exhausted ? "Codex usage limit has been reached." : "Codex usage is low."
    message = "Codex reports #{ERB::Util.html_escape(limit_label)} for this account."
    if (evidence = availability&.dig(:evidence, :current))
      message += " Latest evidence: <code>#{ERB::Util.html_escape(evidence[:status])}</code> from <code>#{ERB::Util.html_escape(evidence[:source])}</code>."
    end
    message += " Usage resets in #{ERB::Util.html_escape(relative_reset_label(reset_at))}." if reset_at.present?

    pause_active = codex_provider_pause_active?(user, availability: availability, remaining: remaining, exhausted: exhausted)
    action_steps = [
      "Pause or move Codex-backed automation to another provider before starting more work.",
      "Recheck after changing the Codex account or plan so Syrus can fetch a new usage snapshot."
    ]
    actions = [
      {
        text: "Recheck Codex",
        method: "post",
        path: "/api/v1/app/credentials/recheck_provider_availability",
        params: { provider: "codex" }
      }
    ]
    if pause_active
      action_steps << "Override only if you are sure the account has usable Codex quota; Syrus will resume paused Codex work subject to normal admission control."
      actions << {
        text: "Resume Codex anyway",
        method: "post",
        path: "/api/v1/app/credentials/override_provider_availability",
        params: { provider: "codex" },
        destructive: exhausted
      }
    end

    Alert.new(
      id: "codex_usage:#{user.id}",
      dismissal_key: codex_usage_dismissal_key(user, snapshot, status: status, reset_at: reset_at),
      severity: exhausted ? :alarm : :warn,
      title: title,
      message: message,
      action_steps: action_steps,
      cta: { text: "Open agent settings", path: "/settings/agent" },
      actions: actions
    )
  end
  private_class_method :codex_usage

  def self.codex_provider_pause_active?(user, availability:, remaining:, exhausted:)
    return false unless user.provider_availability_pause_enabled?("codex")
    return false if availability&.dig(:override_active)
    return true if exhausted
    return false if remaining.blank?

    remaining.to_f < user.provider_availability_pause_threshold_for("codex")
  end
  private_class_method :codex_provider_pause_active?

  def self.codex_usage_dismissal_key(user, snapshot, status:, reset_at:)
    windows = [ snapshot["primary"], snapshot["secondary"] ].compact.map do |window|
      [
        window["label"],
        window["reset_at"],
        window["remaining_percent"].present? ? window["remaining_percent"].to_f.round : nil
      ].compact.join("=")
    end
    "codex_usage:#{user.id}:#{status}:#{reset_at&.iso8601}:#{windows.join("|")}"
  end
  private_class_method :codex_usage_dismissal_key

  def self.codex_usage_reset_at(snapshot, status:)
    candidates = [ snapshot["primary"], snapshot["secondary"] ].compact
    candidates = candidates.select { |window| window["remaining_percent"].present? && window["remaining_percent"].to_f <= CodexUsageProbe::WARNING_REMAINING_PERCENT } if status == "warning"
    candidates = [ snapshot["primary"], snapshot["secondary"] ].compact if candidates.blank?
    reset_values = candidates.filter_map { |window| parse_time(window["reset_at"]) }
    reset_values.min
  end
  private_class_method :codex_usage_reset_at

  def self.parse_time(value)
    Time.zone.parse(value.to_s) if value.present?
  rescue ArgumentError, TypeError
    nil
  end
  private_class_method :parse_time

  def self.relative_reset_label(reset_at, now: Time.current)
    seconds = [ reset_at - now, 0 ].max
    days = (seconds / 1.day).floor
    hours = ((seconds % 1.day) / 1.hour).floor
    minutes = ((seconds % 1.hour) / 1.minute).ceil
    parts = []
    parts << pluralize_unit(days, "day") if days.positive?
    parts << pluralize_unit(hours, "hour") if hours.positive?
    parts << pluralize_unit(minutes, "minute") if parts.empty? && minutes.positive?
    parts.presence&.join(", ") || "less than a minute"
  end
  private_class_method :relative_reset_label

  def self.pluralize_unit(value, unit)
    "#{value} #{unit.pluralize(value)}"
  end
  private_class_method :pluralize_unit

  def self.codex_usage_breakdown(snapshot)
    [ snapshot["primary"], snapshot["secondary"] ].compact.filter_map do |window|
      remaining = window["remaining_percent"]
      next if remaining.blank?

      "#{window.fetch("label", "usage")} #{remaining.round}% remaining"
    end.join(", ")
  end
  private_class_method :codex_usage_breakdown

  # Per-pod under multi-worker: prefer the most-full worker's own reported
  # usage (stamped on its InstanceVersion heartbeat). Falls back to the single
  # cached snapshot (DataRootDiskUsage) on single-worker / dev, where no
  # per-pod instance rows exist.
  def self.data_root_disk_usage
    worst = InstanceVersion.worst_data_root
    if worst
      return unless worst.data_root_alert?

      build_disk_alert(used_percent: worst.data_root_used_percent,
                       available_bytes: worst.data_root_available_bytes,
                       path: worst.data_root_path, level: worst.data_root_alert_level,
                       hostname: worst.hostname)
    else
      snapshot = DataRootDiskUsage.current
      return unless snapshot&.alert?

      build_disk_alert(used_percent: snapshot.used_percent,
                       available_bytes: snapshot.available_bytes,
                       path: snapshot.path, level: snapshot.level, hostname: nil)
    end
  end
  private_class_method :data_root_disk_usage

  def self.build_disk_alert(used_percent:, available_bytes:, path:, level:, hostname:)
    critical = level == :critical
    severity = critical ? :alarm : :warn
    level_label = critical ? "critical" : "high"
    who = hostname.present? ? "Worker <code>#{ERB::Util.html_escape(hostname)}</code>" : "The worker"
    title = hostname.present? ? "Worker #{hostname} data volume usage is #{level_label}." : "Worker data volume usage is #{level_label}."
    path_html = ERB::Util.html_escape(path.to_s)
    # Single-host Docker (Compose / the desktop apps) runs one worker container on
    # a shared Docker volume, so the actionable advice differs from K8s per-pod:
    # the volume competes with everything on the Docker host, and stale images are
    # a common culprit. On K8s each worker fills its own volume, so name the pod.
    single_host = ENV["SYRUS_SQLITE"].present?
    message =
      if single_host
        "The worker's SYRUS_DATA_ROOT (<code>#{path_html}</code>) is #{used_percent}% full " \
          "with #{format_bytes(available_bytes)} available. On single-host Docker this volume " \
          "shares the Docker host's disk."
      else
        "#{who}'s SYRUS_DATA_ROOT (<code>#{path_html}</code>) is #{used_percent}% full " \
          "with #{format_bytes(available_bytes)} available. Each worker fills its own data " \
          "volume, so this is the most-full worker."
      end
    action_steps =
      if single_host
        [
          "Inspect retained workflow workspaces under <code>#{path_html}/workflows</code> and clean up old terminal Workflow workspaces.",
          "Reclaim Docker host disk with <code>docker image prune -f</code> (and <code>docker system prune</code> if safe) — old backend images accumulate across updates.",
          "If this recurs, confirm per-Job workspace pruning is running and that stuck/looping Jobs aren't churning retries."
        ]
      else
        [
          "Inspect retained workflow workspaces under <code>#{path_html}/workflows</code> on that worker and clean up old terminal Workflow workspaces.",
          "If this recurs, confirm per-Job workspace pruning is running and that stuck/looping Jobs aren't churning retries.",
          "If cleanup is not enough, resize that worker's data volume before clone, prepare, or landing jobs start failing."
        ]
      end
    Alert.new(
      id: "data_root_disk_usage",
      dismissal_key: "data_root_disk_usage:#{hostname}:#{level}:#{path}:#{used_percent}",
      severity: severity,
      title: title,
      message: message,
      action_steps: action_steps,
      cta: { text: "Open admin overview", path: "/admin" },
      actions: []
    )
  end
  private_class_method :build_disk_alert

  def self.format_bytes(bytes)
    units = [ [ 1.terabyte, "TB" ], [ 1.gigabyte, "GB" ], [ 1.megabyte, "MB" ] ]
    factor, suffix = units.find { |unit, _| bytes >= unit } || [ 1.kilobyte, "KB" ]
    value = bytes.to_f / factor
    value >= 10 ? "#{value.round}#{suffix}" : "#{value.round(1)}#{suffix}"
  end
  private_class_method :format_bytes
end
