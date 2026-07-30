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

  Alert = Data.define(:id, :severity, :title, :message, :action_steps, :cta)

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
      cta: { text: "Update token", path: "/credentials" }
    )
  end
  private_class_method :github_token_blocked

  def self.codex_usage(user)
    status = user.codex_usage_status.to_s
    return unless %w[exhausted warning].include?(status)

    snapshot = user.codex_usage_snapshot || {}
    remaining = snapshot["remaining_percent"]
    limit_label = codex_usage_breakdown(snapshot).presence || (remaining.present? ? "#{remaining.round}% remaining" : status)
    reset_at = [ snapshot.dig("primary", "reset_at"), snapshot.dig("secondary", "reset_at") ].compact.min
    title = status == "exhausted" ? "Codex usage limit has been reached." : "Codex usage is low."
    message = "Codex reports #{ERB::Util.html_escape(limit_label)} for this account."
    message += " The next reset is around <code>#{ERB::Util.html_escape(reset_at)}</code>." if reset_at.present?

    Alert.new(
      id: "codex_usage:#{user.id}",
      severity: status == "exhausted" ? :alarm : :warn,
      title: title,
      message: message,
      action_steps: [
        "Pause or move Codex-backed automation to another provider before starting more work.",
        "Refresh Credentials after changing the Codex account or plan so Syrus can fetch a new usage snapshot."
      ],
      cta: { text: "Open credentials", path: "/credentials" }
    )
  end
  private_class_method :codex_usage

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
      severity: severity,
      title: title,
      message: message,
      action_steps: action_steps,
      cta: { text: "Open admin overview", path: "/admin" }
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
