class MigrateLandingQueueBlockedReasonToJson < ActiveRecord::Migration[8.1]
  STATIC_REASON_MAP = {
    "landing paused" => { "key" => "landing_paused" },
    "landing paused: main branch broken" => { "key" => "landing_paused_main_broken" },
    "repository archived" => { "key" => "repository_archived" },
    "urgent job active" => { "key" => "urgent_job_active" },
    "waiting for Epic merge-train" => { "key" => "waiting_epic_merge_train" },
    "auto-merge not enabled for repository" => { "key" => "auto_merge_not_enabled" },
    "review requested changes" => { "key" => "review_requested_changes" },
    "missing pull request" => { "key" => "missing_pull_request" },
    "active workflow" => { "key" => "active_workflow" },
    "waiting for Epic to release" => { "key" => "waiting_epic_release" },
    "waiting for epic siblings to be approved" => { "key" => "waiting_epic_siblings" },
    "waiting for GitHub mergeability" => { "key" => "waiting_github_mergeability" },
    "waiting for GitHub mergeability after no-op rebase" => { "key" => "waiting_github_mergeability_noop" },
    "rebase cap reached; manual rebase or PR update required" => { "key" => "rebase_cap_reached" },
    "epic reconciliation pending" => { "key" => "epic_reconciliation_pending" }
  }.freeze

  DYNAMIC_PATTERNS = [
    [ /\Aci_failure workflow in progress on (.+)\z/, ->(m) { { "key" => "ci_failure_in_progress", "params" => { "slug" => m[1] } } } ],
    [ /\APR checks failing on (.+)\z/, ->(m) { { "key" => "pr_checks_failing", "params" => { "slug" => m[1] } } } ],
    [ /\APR checks pending on (.+)\z/, ->(m) { { "key" => "pr_checks_pending", "params" => { "slug" => m[1] } } } ],
    [ /\Awaiting for (.+) to merge\z/, ->(m) { { "key" => "waiting_to_merge", "params" => { "slug" => m[1] } } } ],
    [ /\Awaiting for Epic #(\d+) to complete\z/, ->(m) { { "key" => "waiting_epic_to_complete", "params" => { "number" => m[1].to_i } } } ]
  ].freeze

  def up
    add_column :jobs, :landing_queue_blocked_reason_new, :json unless column_exists?(:jobs, :landing_queue_blocked_reason_new)

    connection.select_all("SELECT id, landing_queue_blocked_reason FROM jobs WHERE landing_queue_blocked_reason IS NOT NULL").each do |row|
      structured = convert_reason(row["landing_queue_blocked_reason"])
      connection.execute(
        "UPDATE jobs SET landing_queue_blocked_reason_new = #{connection.quote(structured.to_json)} WHERE id = #{connection.quote(row['id'])}"
      )
    end

    remove_column :jobs, :landing_queue_blocked_reason if column_exists?(:jobs, :landing_queue_blocked_reason)
    rename_column :jobs, :landing_queue_blocked_reason_new, :landing_queue_blocked_reason
  end

  def down
    add_column :jobs, :landing_queue_blocked_reason_old, :string unless column_exists?(:jobs, :landing_queue_blocked_reason_old)

    connection.select_all("SELECT id, landing_queue_blocked_reason FROM jobs WHERE landing_queue_blocked_reason IS NOT NULL").each do |row|
      value = JSON.parse(row["landing_queue_blocked_reason"]) rescue nil
      next unless value.is_a?(Hash) && value["key"]
      connection.execute(
        "UPDATE jobs SET landing_queue_blocked_reason_old = #{connection.quote(value["key"])} WHERE id = #{connection.quote(row['id'])}"
      )
    end

    remove_column :jobs, :landing_queue_blocked_reason if column_exists?(:jobs, :landing_queue_blocked_reason)
    rename_column :jobs, :landing_queue_blocked_reason_old, :landing_queue_blocked_reason
  end

  private

  def convert_reason(raw)
    return STATIC_REASON_MAP[raw] if STATIC_REASON_MAP.key?(raw)
    DYNAMIC_PATTERNS.each do |pattern, builder|
      match = raw.match(pattern)
      return builder.call(match) if match
    end
    { "key" => "unknown", "params" => { "raw" => raw } }
  end
end
