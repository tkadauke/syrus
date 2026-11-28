# What Syrus does about requested changes on a bot-authored external PR.
#
# A human contributor reads a CHANGES_REQUESTED review and pushes a fix, so for
# their PRs Syrus waits (PollExternalPrJob holds the Job on
# `upstream_pr_changes_requested`). Dependabot, Renovate and other GitHub Apps
# never act on review feedback: waiting for them is a dead end, and an approved
# Job could sit in the landing queue for months. When the bot's head branch
# lives in the tracked repository Syrus can push to it, so it takes the review
# on itself:
#
# 1. superseded -- the same bot opened a newer PR for the same dependency (or
#    one already merged): close the Job.
# 2. stale -- the PR is older than `max_age_days`, or more than
#    `max_commits_behind` commits behind its base, or Syrus's repair of the
#    review failed: ask Dependabot to recreate the PR (once), else close.
# 3. otherwise repair -- launch the same external_pr_feedback fix-and-push
#    workflow a maintainer comment would, with the review bodies as the
#    feedback, once per review.
#
# Bot authorship is read from the polled PR's author (`type: Bot` or a
# `[bot]` login), never from Job text. Configured through
# `external_prs.bot_prs` in `.syrus.yml`; an unreadable config waits, as
# before. Human-authored and fork PRs are never touched.
class ExternalPrBotPolicy
  DEPENDABOT_LOGIN = "dependabot[bot]".freeze
  RECREATE_COMMENT = "@dependabot recreate".freeze
  SUPERSEDED_CLOSURE_REASON = "external_pr_superseded".freeze
  STALE_CLOSURE_REASON = "external_pr_stale".freeze
  CLOSURE_REASONS = [ SUPERSEDED_CLOSURE_REASON, STALE_CLOSURE_REASON ].freeze
  # Dependabot is asked to recreate a PR at most this many times per Job; a
  # recreated PR that goes stale again is closed.
  MAX_REFRESHES = 1
  # How long a recreate request may go unanswered (the head does not move)
  # before the Job is closed instead.
  REFRESH_GRACE = 1.day
  # A trailing version segment of a bot branch: `-5`, `-8.1.0`, `-v2`, `-2.x`.
  BRANCH_VERSION_SUFFIX = /-v?\d[\w.]*\z/

  def self.bot_author?(pr)
    user = value(pr, :user)
    login = value(user, :login).to_s.strip.downcase
    type = value(user, :type).to_s.strip.downcase
    return false if login.blank?

    type == "bot" || login.end_with?("[bot]")
  end

  # A command addressed to a dependency bot (`@dependabot recreate`), whoever
  # wrote it, is not review feedback for an agent to act on.
  def self.bot_command?(body)
    body.to_s.strip.match?(/\A@(dependabot|renovate)(\[bot\])?\s/i)
  end

  def self.value(resource, key)
    return unless resource
    return resource.public_send(key) if resource.respond_to?(key)
    if resource.respond_to?(:[]) && resource.respond_to?(:key?)
      return resource[key] if resource.key?(key)
      return resource[key.to_s] if resource.key?(key.to_s)
    end

    nil
  end

  # The dependency a bot branch updates, with the version stripped:
  # `dependabot/bundler/rack-3.1.1` and `dependabot/bundler/rack-3.2.0` share
  # `dependabot/bundler/rack`.
  def self.dependency_key(branch_name)
    branch_name.to_s.strip.sub(BRANCH_VERSION_SUFFIX, "").presence
  end

  def self.call(job:, pr:, client:, changes_requested:, now: Time.current, config: nil)
    new(job:, pr:, client:, changes_requested:, now:, config:).call
  end

  def initialize(job:, pr:, client:, changes_requested:, now:, config:)
    @job = job
    @pr = pr
    @client = client
    @changes_requested = Array(changes_requested)
    @now = now
    @config = config
  end

  # Returns the outcome as a symbol, for logging and specs.
  def call
    return :not_applicable unless applies?

    settings = bot_settings
    return :config_unavailable unless settings

    return close!(SUPERSEDED_CLOSURE_REASON, "superseded by #{superseding_job.slug}") if superseding_job

    case refresh_state
    when :pending then return :refresh_pending
    when :unanswered then return close!(STALE_CLOSURE_REASON, "recreate request unanswered")
    when :answered then acknowledge_recreated_head!
    end

    stale_reason = staleness_reason(settings)
    return go_stale!(settings, stale_reason) if stale_reason
    return :waiting unless settings.repair?

    pending = changes_requested.reject { |review| repaired_review_ids.include?(review_id(review)) }
    return dispatch_repair!(pending) if pending.any?

    latest_repair&.failed? ? go_stale!(settings, "repair_failed") : :waiting
  end

  private

  attr_reader :job, :pr, :client, :changes_requested, :now

  def applies?
    return false unless job.external_pr? && job.external_pr_number.present?
    return false if job.external_pr_fork?
    return false unless self.class.bot_author?(pr)

    head_repository == job.repository.slug
  end

  def head_repository
    self.class.value(self.class.value(self.class.value(pr, :head), :repo), :full_name).to_s
  end

  def dependabot?
    self.class.value(self.class.value(pr, :user), :login).to_s.strip.downcase == DEPENDABOT_LOGIN
  end

  def bot_settings
    return @config if @config

    loaded = RepoDefaultBranchSyrusYml.new(repository: job.repository, user: job.user).resolve
    return nil unless loaded.determined?

    loaded.config&.external_prs&.bot_prs || SyrusYml::ExternalBotPrsConfig.default
  end

  # ----- superseded ---------------------------------------------------------

  def superseding_job
    return @superseding_job if defined?(@superseding_job)

    key = self.class.dependency_key(job.branch_name)
    @superseding_job = if key && job.external_pr_author.present?
      Job.external_pr_kind
         .where(repository_id: job.repository_id, external_pr_author: job.external_pr_author)
         .where("external_pr_number > ?", job.external_pr_number)
         .where.not(id: job.id)
         .where("jobs.state <> 'closed' OR jobs.closure_reason = 'external_pr_merged'")
         .order(external_pr_number: :desc)
         .detect { |candidate| self.class.dependency_key(candidate.branch_name) == key }
    end
  end

  # ----- stale --------------------------------------------------------------

  def staleness_reason(settings)
    max_age = settings.max_age_days.to_i
    return "older_than_#{max_age}_days" if max_age.positive? && age_anchor && age_anchor < now - max_age.days

    max_behind = settings.max_commits_behind.to_i
    return "more_than_#{max_behind}_commits_behind" if max_behind.positive? && job.commits_behind_base.to_i > max_behind

    nil
  end

  # A recreated PR keeps its number and creation date; its age restarts at
  # the recreate request.
  def age_anchor
    created = parse_time(self.class.value(pr, :created_at))
    refreshed = parse_time(recovery["refresh_requested_at"])
    [ created, refreshed ].compact.max
  end

  def go_stale!(settings, reason)
    case settings.stale_action
    when "wait" then :waiting
    when "close" then close!(STALE_CLOSURE_REASON, reason)
    else refresh_or_close!(reason)
    end
  end

  def refresh_or_close!(reason)
    return close!(STALE_CLOSURE_REASON, reason) unless dependabot?
    return close!(STALE_CLOSURE_REASON, reason) if refresh_count >= MAX_REFRESHES

    client.add_issue_comment(job.repository.slug, job.external_pr_number, RECREATE_COMMENT)
    record!(
      "refresh_requested_at" => now.iso8601,
      "refresh_head_sha" => head_sha,
      "refresh_count" => refresh_count + 1,
      "refresh_reason" => reason,
      "refresh_answered_at" => nil
    )
    audit("asked Dependabot to recreate external PR ##{job.external_pr_number} (#{reason})")
    :refresh_requested
  rescue Octokit::Error => e
    # Nothing recorded: the next poll asks again.
    Rails.logger.warn("[ExternalPrBotPolicy] #{job.slug}: recreate request failed: #{e.class}: #{e.message}")
    :refresh_failed
  end

  # Where the last recreate request stands. Dependabot answers it by
  # force-pushing a new head to the same PR.
  def refresh_state
    requested_at = parse_time(recovery["refresh_requested_at"])
    return :none unless requested_at
    return :none if recovery["refresh_answered_at"].present?
    return :answered if recovery["refresh_head_sha"].present? && head_sha.present? && recovery["refresh_head_sha"] != head_sha

    requested_at > now - REFRESH_GRACE ? :pending : :unanswered
  end

  # The recreated PR is new code: repairs of the old head do not apply to it.
  def acknowledge_recreated_head!
    record!("refresh_answered_at" => now.iso8601, "refresh_answered_head_sha" => head_sha, "repaired_review_ids" => [])
  end

  def close!(reason, detail)
    record!("closed_reason" => reason, "closed_detail" => detail, "closed_at" => now.iso8601)
    audit("closing bot-authored external PR Job: #{reason} (#{detail})")
    JobClosure.request!(job, reason)
    reason == SUPERSEDED_CLOSURE_REASON ? :closed_superseded : :closed_stale
  end

  # ----- repair -------------------------------------------------------------

  def dispatch_repair!(reviews)
    workflow = nil
    job.with_lock do
      job.reload(lock: true)
      return :repair_active if WorkUnits::Ownership.active_for_job_kind?(job, Workflow::TriggerKind.feedback_values)

      job.stop_landing! if job.landing?
      job.reload(lock: true)
      Job::ApprovalUnapprover.call(job: job, user: job.user) if job.may_unapprove?

      ids = reviews.map { |review| review_id(review) }.compact
      workflow = WorkUnits::Launcher.instantiate(
        kind: "external_pr_feedback",
        job: job,
        artifacts: {
          "pr_comments" => reviews.map { |review| serialize_review(review) },
          "feedback_cutoff" => nil,
          "pr_feedback_iteration" => job.workflows.where(trigger_kind: Workflow::TriggerKind.feedback_values).count + 1,
          "pr_feedback_auto" => true,
          "pr_feedback_source_handle" => reviews.filter_map { |review| review_author(review) }.first,
          "external_pr_bot_review_ids" => ids
        },
        agent_provider: job.workflow_agent_provider
      )
      record!(
        "repaired_review_ids" => (repaired_review_ids + ids).uniq,
        "repair_workflow_id" => workflow.id,
        "repair_requested_at" => now.iso8601
      )
    end
    WorkUnits::Launcher.start!(workflow)
    audit("launched #{workflow.slug} to address requested changes on bot-authored external PR ##{job.external_pr_number}")
    :repair_dispatched
  rescue WorkUnits::Launcher::LockConflict
    :repair_active
  end

  def latest_repair
    id = recovery["repair_workflow_id"]
    id && Workflow.find_by(id: id, job_id: job.id)
  end

  def serialize_review(review)
    author = review_author(review)
    {
      "id" => review_id(review),
      "author" => author,
      "body" => self.class.value(review, :body).to_s,
      "path" => nil,
      "line" => nil,
      "diff_hunk" => nil,
      "created_at" => parse_time(self.class.value(review, :submitted_at))&.iso8601,
      "attributed_to" => PrCommentAttributor.call(github_handle: author.to_s, job: job)
    }
  end

  def review_id(review) = self.class.value(review, :id)

  def review_author(review) = self.class.value(self.class.value(review, :user), :login)

  # ----- bookkeeping --------------------------------------------------------

  def recovery
    job.external_pr_bot_recovery.is_a?(Hash) ? job.external_pr_bot_recovery : {}
  end

  def repaired_review_ids = Array(recovery["repaired_review_ids"])

  def refresh_count = recovery["refresh_count"].to_i

  def record!(attributes)
    job.update_columns(external_pr_bot_recovery: recovery.merge(attributes), updated_at: Time.current)
  end

  def head_sha
    self.class.value(self.class.value(pr, :head), :sha).to_s.presence
  end

  def audit(message)
    Rails.logger.info("[ExternalPrBotPolicy] #{job.slug}: #{message}")
  end

  def parse_time(value)
    return if value.blank?
    return value.to_time if value.respond_to?(:to_time) && !value.is_a?(String)

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
