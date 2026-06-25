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

  def self.data_root_disk_usage
    snapshot = DataRootDiskUsage.current
    return unless snapshot&.alert?

    critical = snapshot.level == :critical
    severity = critical ? :alarm : :warn
    level_label = critical ? "critical" : "high"
    Alert.new(
      id: "data_root_disk_usage",
      severity: severity,
      title: "Worker data volume usage is #{level_label}.",
      message: "SYRUS_DATA_ROOT is #{snapshot.used_percent}% full with " \
               "#{format_bytes(snapshot.available_bytes)} available. " \
               "Data root: <code>#{ERB::Util.html_escape(snapshot.path)}</code>.",
      action_steps: [
        "Inspect retained workflow workspaces under <code>#{ERB::Util.html_escape(snapshot.path)}/workflows</code> and clean up old terminal Workflow workspaces.",
        "If cleanup is not enough, resize the worker data volume before clone, prepare, or landing jobs start failing."
      ],
      cta: { text: "Open admin overview", path: "/admin" }
    )
  end
  private_class_method :data_root_disk_usage

  def self.format_bytes(bytes)
    units = [ [ 1.terabyte, "TB" ], [ 1.gigabyte, "GB" ], [ 1.megabyte, "MB" ] ]
    factor, suffix = units.find { |unit, _| bytes >= unit } || [ 1.kilobyte, "KB" ]
    value = bytes.to_f / factor
    value >= 10 ? "#{value.round}#{suffix}" : "#{value.round(1)}#{suffix}"
  end
  private_class_method :format_bytes
end
