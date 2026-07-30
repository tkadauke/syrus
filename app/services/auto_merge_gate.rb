class AutoMergeGate
  OPT_OUT_LABEL = "syrus-no-automerge".freeze
  WRITE_ASSOCIATIONS = %w[OWNER MEMBER COLLABORATOR].freeze
  TRANSIENT_MERGEABLE_STATES = %w[unknown has_hooks].freeze

  # Approval vias the operator deliberately set via Syrus UI or
  # configuration — distinct from `github_review`, which is the
  # PR-review-mirror path (and already counted via formal_approval?).
  # New approval mechanisms in Syrus should add their via here so the
  # gate honors them without a separate code change.
  SYRUS_SIDE_APPROVAL_VIAS = %w[operator bulk auto_rule].freeze

  Result = Struct.new(:outcome, :approved, :reason, :pr, keyword_init: true) do
    def merge_ready? = outcome == :ready
    def closed? = outcome == :closed
    def approved? = approved
    def transient? = outcome == :transient
    def needs_rebase? = outcome == :needs_rebase
    def blocked? = outcome == :blocked
  end

  def initialize(job:, client: GithubClient.for(repository: job.repository, user: job.user), bypass_cache: false, pr: nil)
    @job = job
    @repository = job.repository
    @client = client
    @bypass_cache = bypass_cache
    @pr = pr
  end

  def evaluate
    return blocked("auto-merge is globally disabled") if AppSetting.auto_merge_paused?
    return blocked("repository has not enabled auto-merge") unless @job.auto_merge_enabled?
    return blocked("job has no Syrus PR") unless @job.pr_number.present?
    return blocked("job has unsatisfied dependencies") unless @job.dependencies_satisfied?

    pr = @pr || @client.pull_request(@repository.slug, @job.pr_number, bypass_cache: @bypass_cache)
    return Result.new(outcome: :closed, approved: false, reason: "PR is closed", pr: pr) if pr.state == "closed"
    return blocked("PR has #{OPT_OUT_LABEL}", pr: pr) if has_label?(pr, OPT_OUT_LABEL)

    approved = approved?(pr)
    return blocked("PR is not approved", pr: pr, approved: false) unless approved

    case mergeable_state(pr)
    when "clean", "unstable"
      # `unstable` means a non-required CI check is failing — the
      # merge call itself would succeed. Operator approved knowing
      # the PR's state; the failing check isn't gating. If the repo
      # has stricter branch protection that we didn't anticipate,
      # the merge_pull_request call will surface that via
      # TRANSIENT_MERGE_ERRORS and defer (approval preserved).
      Result.new(outcome: :ready, approved: true, reason: "approved and #{mergeable_state(pr)}", pr: pr)
    when "behind", "dirty"
      # `behind` means the base branch moved forward — clean rebase
      # fixes it. `dirty` means there are merge conflicts — the
      # agent-driven rebase chain (auto_rebase → agent_rebase →
      # force_push) is specifically designed to resolve them, so
      # treat both as :needs_rebase rather than blocking outright.
      Result.new(outcome: :needs_rebase, approved: true, reason: "PR mergeable_state is #{mergeable_state(pr).inspect}", pr: pr)
    when *TRANSIENT_MERGEABLE_STATES
      Result.new(outcome: :transient, approved: true, reason: "PR mergeable_state is #{mergeable_state(pr).inspect}", pr: pr)
    else
      blocked("PR mergeable_state is #{mergeable_state(pr).inspect}", pr: pr, approved: true)
    end
  end

  private

  def blocked(reason, pr: nil, approved: false)
    Result.new(outcome: :blocked, approved: approved, reason: reason, pr: pr)
  end

  def has_label?(pr, name)
    Array(pr.labels).any? { |label| label.name == name }
  end

  def mergeable_state(pr)
    pr.respond_to?(:mergeable_state) ? pr.mergeable_state : nil
  end

  def approved?(pr)
    syrus_side_approval? || formal_approval?(pr) || slash_approval?(pr)
  end

  # The operator deliberately approved this Job via Syrus — single-
  # job Approve button (`via: "operator"`), bulk approve from the
  # dashboard (`via: "bulk"`), or an auto-approval rule the operator
  # configured (`via: "auto_rule"`). All three express the same
  # human intent and should pass the gate without re-checking
  # GitHub. The github_review via is intentionally excluded; the
  # GitHub side already passes via formal_approval?.
  #
  # We deliberately do NOT use Job#approved? here. That's the AASM
  # state predicate; by the time AutoMerge runs the gate, the Job
  # has already transitioned :approved → :landing, so #approved?
  # returns false even though the operator did approve. The
  # persistent metadata columns (approved_via + approved_at) are
  # the source of truth — fail_landing / defer_landing clear them,
  # so "syrus-side via + at present" really does mean "still
  # approved" regardless of current state.
  def syrus_side_approval?
    SYRUS_SIDE_APPROVAL_VIAS.include?(@job.approved_via.to_s) && @job.approved_at.present?
  end

  def formal_approval?(_pr)
    @client.pr_reviews(@repository.slug, @job.pr_number).any? { |review| review.state == "APPROVED" }
  end

  def slash_approval?(pr)
    latest = latest_valid_slash_command(pr)
    latest&.approve? == true
  end

  def latest_valid_slash_command(pr)
    @client.pr_issue_comments(@repository.slug, @job.pr_number).filter_map do |comment|
      parsed = SlashCommandParser.parse(comment.body)
      next unless parsed
      next unless WRITE_ASSOCIATIONS.include?(comment.author_association.to_s)
      next if stale_comment?(pr, comment.created_at)

      audit_slash_command(comment, parsed)
      [ comment.created_at, parsed ]
    end.max_by(&:first)&.last
  end

  def stale_comment?(pr, created_at)
    return true unless created_at
    head_sha = pr.head&.sha
    return false if head_sha.blank?

    commits = @client.pr_commits(@repository.slug, @job.pr_number)
    commits.any? do |commit|
      sha = commit.respond_to?(:sha) ? commit.sha : nil
      next false if sha.blank? || sha == head_sha && commit_date(commit).nil?

      date = commit_date(commit)
      date && date > created_at
    end
  end

  def commit_date(commit)
    commit.commit&.committer&.date || commit.commit&.author&.date
  end

  def audit_slash_command(comment, parsed)
    run = @job.current_run
    return unless run

    JobLog.append!(
      run: run,
      kind: "system",
      chunk: "auto_merge: recognized #{parsed.command} from @#{comment.user&.login}"
    )
  end
end
