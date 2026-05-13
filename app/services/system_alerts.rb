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
# `.active_for`. The view layer doesn't change — the
# `shared/_alert_banner` partial renders any Alert by its severity,
# title, message, and action_steps.
module SystemAlerts
  Alert = Data.define(:id, :severity, :title, :message, :action_steps, :cta) do
    # Severity drives color in the banner partial:
    #   :alarm — red, "this is broken right now"
    #   :warn  — amber, "this is degraded but limping"
    #   :info  — blue, "you should know about this"
    SEVERITIES = %i[ alarm warn info ].freeze
  end

  def self.active_for(user:)
    out = []
    out << github_token_blocked(user) if user&.gh_api_blocked?
    out
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
               "<code>#{reason}</code>. PR-feedback polling is degraded until this is fixed; " \
               "the banner clears automatically on the next successful API call.",
      action_steps: [
        "Generate a <strong>classic</strong> PAT at " \
          "<a class=\"underline\" href=\"https://github.com/settings/tokens\">github.com/settings/tokens</a> " \
          "with the <code>repo</code> scope (which covers the Syrus surface — clone, push, PRs, and comments).",
        "Fine-grained PATs may work for narrower setups, but the token must still be able to read pull requests and review comments.",
        "Paste the new token into <a class=\"underline\" href=\"/credentials/edit\">Settings → Credentials</a> and save. " \
          "The banner clears on the next successful API call."
      ],
      cta: { text: "Update token", path: "/credentials/edit" }
    )
  end
  private_class_method :github_token_blocked
end
