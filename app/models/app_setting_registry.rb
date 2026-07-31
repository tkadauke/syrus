class AppSettingRegistry
  Definition = Data.define(
    :key,
    :type,
    :default,
    :category,
    :operational_meaning,
    :min,
    :max,
    :zero_means,
    :admin_editable,
    :secret
  ) do
    def integer?
      type == :integer
    end

    def boolean?
      type == :boolean
    end

    def numericality_options
      return unless integer?

      { only_integer: true }.tap do |options|
        options[:greater_than_or_equal_to] = min unless min.nil?
        options[:less_than_or_equal_to] = max unless max.nil?
      end
    end

    def as_json(*)
      {
        key: key.to_s,
        type: type.to_s,
        default: default,
        category: category,
        operational_meaning: operational_meaning,
        min: min,
        max: max,
        zero_means: zero_means,
        admin_editable: admin_editable,
        secret: secret
      }.compact
    end
  end

  DEFINITIONS = [
    Definition.new(
      key: :grade_max_iterations,
      type: :integer,
      default: 5,
      min: 1,
      max: 10,
      category: "Workflow behavior",
      operational_meaning: "Maximum number of repair-check cycles in the grader loop before a workflow fails.",
      zero_means: nil,
      admin_editable: false,
      secret: false
    ),
    Definition.new(
      key: :adversarial_review_rounds,
      type: :integer,
      default: 0,
      min: 0,
      max: 10,
      category: "Workflow behavior",
      operational_meaning: "Number of implement-to-adversarial-review iterations run before graders.",
      zero_means: "Adversarial review is disabled instance-wide.",
      admin_editable: false,
      secret: false
    ),
    Definition.new(
      key: :max_job_failures,
      type: :integer,
      default: 3,
      min: nil,
      max: nil,
      category: "Workflow behavior",
      operational_meaning: "Consecutive failure threshold used by scheduled task auto-pause and provider retry suppression.",
      zero_means: "Auto-pause is disabled.",
      admin_editable: false,
      secret: false
    ),
    Definition.new(
      key: :merge_train_enabled,
      type: :boolean,
      default: false,
      min: nil,
      max: nil,
      category: "Landing queue",
      operational_meaning: "Approved Epic child Jobs land through an atomic merge-train workflow instead of one-by-one auto-merge.",
      zero_means: nil,
      admin_editable: false,
      secret: false
    ),
    Definition.new(
      key: :merge_train_max_size,
      type: :integer,
      default: 20,
      min: nil,
      max: nil,
      category: "Landing queue",
      operational_meaning: "Maximum number of PRs that can participate in one merge train.",
      zero_means: nil,
      admin_editable: false,
      secret: false
    ),
    Definition.new(
      key: :signups_open,
      type: :boolean,
      default: false,
      min: nil,
      max: nil,
      category: "Instance operations",
      operational_meaning: "Allows new user registrations on the instance.",
      zero_means: nil,
      admin_editable: true,
      secret: false
    ),
    Definition.new(
      key: :polling_paused,
      type: :boolean,
      default: false,
      min: nil,
      max: nil,
      category: "Instance operations",
      operational_meaning: "Emergency kill switch that pauses repository, pull request, merge-state, and scheduled-task polling.",
      zero_means: nil,
      admin_editable: false,
      secret: false
    ),
    Definition.new(
      key: :runs_paused,
      type: :boolean,
      default: false,
      min: nil,
      max: nil,
      category: "Instance operations",
      operational_meaning: "Emergency kill switch that keeps workflow Runs queued without losing state.",
      zero_means: nil,
      admin_editable: false,
      secret: false
    ),
    Definition.new(
      key: :report_issue_repo_slug,
      type: :string,
      default: "tkadauke/syrus",
      min: nil,
      max: nil,
      category: "Instance operations",
      operational_meaning: "Repository slug used for in-app bug report routing and the Report an issue UI link.",
      zero_means: nil,
      admin_editable: false,
      secret: false
    ),
    Definition.new(
      key: :max_concurrent_agent_runs,
      type: :integer,
      default: 0,
      min: 0,
      max: nil,
      category: "Instance operations",
      operational_meaning: "Global cluster-wide cap on concurrently executing agent Runs across all worker pods.",
      zero_means: "No global cap; each worker is bounded only by its per-pod JOB_CONCURRENCY.",
      admin_editable: true,
      secret: false
    ),
    Definition.new(
      key: :proactive_rebase_commit_threshold,
      type: :integer,
      default: 20,
      min: 1,
      max: nil,
      category: "Instance operations",
      operational_meaning: "Commits-behind threshold that triggers proactive PR rebase maintenance while mergeability is still clean.",
      zero_means: nil,
      admin_editable: true,
      secret: false
    ),
    Definition.new(
      key: :github_app_id,
      type: :bigint,
      default: nil,
      min: nil,
      max: nil,
      category: "GitHub App",
      operational_meaning: "Numeric ID of the registered GitHub App.",
      zero_means: nil,
      admin_editable: false,
      secret: false
    ),
    Definition.new(
      key: :github_app_private_key_pem,
      type: :text,
      default: nil,
      min: nil,
      max: nil,
      category: "GitHub App",
      operational_meaning: "Encrypted RSA private key PEM used to sign GitHub App JWTs.",
      zero_means: nil,
      admin_editable: false,
      secret: true
    ),
    Definition.new(
      key: :github_app_slug,
      type: :string,
      default: nil,
      min: nil,
      max: nil,
      category: "GitHub App",
      operational_meaning: "URL slug of the registered GitHub App.",
      zero_means: nil,
      admin_editable: false,
      secret: false
    ),
    Definition.new(
      key: :github_app_registered_at,
      type: :datetime,
      default: nil,
      min: nil,
      max: nil,
      category: "GitHub App",
      operational_meaning: "Timestamp for GitHub App registration; informational only.",
      zero_means: nil,
      admin_editable: false,
      secret: false
    ),
    Definition.new(
      key: :video_retention_days,
      type: :integer,
      default: 7,
      min: 1,
      max: nil,
      category: "Video walkthroughs",
      operational_meaning: "Days to retain stored walkthrough video blobs before pruning; analysis and screenshots persist.",
      zero_means: nil,
      admin_editable: true,
      secret: false
    ),
    Definition.new(
      key: :video_storage_budget_mb,
      type: :integer,
      default: 2048,
      min: 0,
      max: nil,
      category: "Video walkthroughs",
      operational_meaning: "Instance-wide storage budget for walkthrough video blobs, in megabytes.",
      zero_means: "Size cap is disabled; time-based retention still applies.",
      admin_editable: true,
      secret: false
    ),
    Definition.new(
      key: :chat_coding_workspace_budget_mb,
      type: :integer,
      default: 0,
      min: 0,
      max: nil,
      category: "Coding-Mode workspaces",
      operational_meaning: "Instance-wide disk budget for retained Coding-Mode chat checkouts, in megabytes.",
      zero_means: "Size cap is disabled; idle reclaim and reclaim-on-handoff still apply.",
      admin_editable: false,
      secret: false
    ),
    Definition.new(
      key: :main_concern_report_threshold,
      type: :integer,
      default: 2,
      min: 1,
      max: nil,
      category: "Instance operations",
      operational_meaning: "Minimum repeated broken-main reports before the aggregator surfaces a main-branch concern.",
      zero_means: nil,
      admin_editable: false,
      secret: false
    )
  ].freeze

  BY_KEY = DEFINITIONS.index_by(&:key).freeze

  def self.definitions
    DEFINITIONS
  end

  def self.fetch(key)
    BY_KEY.fetch(key.to_sym)
  end

  def self.admin_editable_keys
    definitions.select(&:admin_editable).map(&:key)
  end

  def self.boolean_key?(key)
    BY_KEY[key.to_sym]&.boolean? || false
  end

  def self.metadata_for(keys = definitions.map(&:key))
    keys.map { |key| fetch(key).as_json }
  end
end
