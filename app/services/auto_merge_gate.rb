class AutoMergeGate
  OPT_OUT_LABEL = "syrus-no-automerge".freeze
  WRITE_ASSOCIATIONS = %w[OWNER MEMBER COLLABORATOR].freeze

  Result = Struct.new(:merge_ready, :closed, :approved, :reason, :pr, keyword_init: true) do
    def merge_ready? = merge_ready
    def closed? = closed
    def approved? = approved
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
    return blocked("repository has not enabled auto-merge") unless @repository.auto_merge_enabled?
    return blocked("job has no Syrus PR") unless @job.pr_number.present?

    pr = @pr || @client.pull_request(@repository.slug, @job.pr_number, bypass_cache: @bypass_cache)
    return Result.new(merge_ready: false, closed: true, approved: false, reason: "PR is closed", pr: pr) if pr.state == "closed"
    return blocked("PR has #{OPT_OUT_LABEL}", pr: pr) if has_label?(pr, OPT_OUT_LABEL)

    approved = approved?(pr)
    return blocked("PR is not approved", pr: pr, approved: false) unless approved
    return blocked("PR mergeable_state is #{mergeable_state(pr).inspect}", pr: pr, approved: true) unless clean?(pr)

    Result.new(merge_ready: true, closed: false, approved: true, reason: "approved and clean", pr: pr)
  end

  private

  def blocked(reason, pr: nil, approved: false)
    Result.new(merge_ready: false, closed: false, approved: approved, reason: reason, pr: pr)
  end

  def has_label?(pr, name)
    Array(pr.labels).any? { |label| label.name == name }
  end

  def clean?(pr)
    mergeable_state(pr) == "clean"
  end

  def mergeable_state(pr)
    pr.respond_to?(:mergeable_state) ? pr.mergeable_state : nil
  end

  def approved?(pr)
    formal_approval?(pr) || slash_approval?(pr)
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

    seq = (run.job_logs.maximum(:sequence) || -1) + 1
    run.job_logs.create!(
      sequence: seq,
      kind: "system",
      chunk: "auto_merge: recognized #{parsed.command} from @#{comment.user&.login}"
    )
  end
end
