module CognitiveEngagementEvents
  class SourceIngestor
    APPROVAL_CONFIDENCE = BigDecimal("0.25")
    APPROVAL_WEIGHT = BigDecimal("0.2")
    PR_COMMENT_CONFIDENCE = BigDecimal("0.65")

    Result = Struct.new(
      :diff_review_comments,
      :job_approvals,
      :job_approval_snapshots,
      :pr_review_comments,
      :authored_commits,
      keyword_init: true
    ) do
      def initialize(**)
        super
        self.diff_review_comments ||= 0
        self.job_approvals ||= 0
        self.job_approval_snapshots ||= 0
        self.pr_review_comments ||= 0
        self.authored_commits ||= 0
      end

      def total_events
        diff_review_comments + job_approvals + job_approval_snapshots + pr_review_comments + authored_commits
      end
    end

    PrAnchor = Data.define(:path, :side, :start_line, :end_line, :anchor_kind)

    def self.call(repository:, commit_source: nil)
      new(repository: repository, commit_source: commit_source).call
    end

    def initialize(repository:, commit_source: nil)
      @repository = repository
      @commit_source = commit_source
      @result = Result.new
    end

    def call
      ingest_diff_review_comments
      ingest_job_approvals
      ingest_job_approval_snapshots
      ingest_pr_review_comments
      ingest_human_authored_commits
      result
    end

    private

    attr_reader :repository, :commit_source, :result

    def ingest_diff_review_comments
      scope = DiffReviewComment.joins(:job)
        .where(jobs: { repository_id: repository.id })
        .includes(:job, :diff_review_version, :user)

      scope.find_each do |comment|
        next unless comment.line_anchor?

        line = comment.side == "left" ? comment.old_line : comment.new_line
        next if line.blank?

        version = comment.diff_review_version
        upsert_event(
          repository: repository,
          user: comment.user,
          diff_review_version: version,
          source_type: "diff_review_comment",
          engagement_kind: "reviewed",
          evidence_type: "DiffReviewComment",
          evidence_id: comment.id,
          evidence_key: "diff_review_comment:#{comment.id}",
          occurred_at: comment.submitted_at || comment.created_at,
          base_sha: version.base_sha,
          head_sha: version.head_sha,
          path: comment.path,
          side: comment.side,
          start_line: line,
          end_line: line,
          confidence: BigDecimal("0.95"),
          quality: "high",
          metadata: {
            "state" => comment.state,
            "surface" => comment.surface,
            "anchor_key" => comment.anchor_key
          }
        )
        result.diff_review_comments += 1
      end
    end

    def ingest_job_approvals
      repository.jobs.includes(:job_approvals, :diff_review_versions).find_each do |job|
        job.job_approvals.includes(:user).find_each do |approval|
          version = reviewed_version_for(job, approval.approved_at)
          ingest_approval_ranges(
            user: approval.user,
            version: version,
            evidence_type: "JobApproval",
            evidence_id: approval.id,
            evidence_key: "job_approval:#{approval.id}",
            occurred_at: approval.approved_at,
            metadata: { "approval_source" => "job_approval", "job_id" => job.id }
          ) { result.job_approvals += 1 }
        end
      end
    end

    def ingest_job_approval_snapshots
      repository.jobs.where.not(approved_at: nil).includes(:approved_by_user, :diff_review_versions).find_each do |job|
        user = job.approved_by_user
        next unless user

        version = reviewed_version_for(job, job.approved_at)
        ingest_approval_ranges(
          user: user,
          version: version,
          evidence_type: "Job",
          evidence_id: job.id,
          evidence_key: "job_approved_snapshot:#{job.id}:#{job.approved_at.to_i}",
          occurred_at: job.approved_at,
          metadata: {
            "approval_source" => "job_snapshot",
            "approved_via" => job.approved_via,
            "approval_evidence" => job.approval_evidence
          }
        ) { result.job_approval_snapshots += 1 }
      end
    end

    def ingest_approval_ranges(user:, version:, evidence_type:, evidence_id:, evidence_key:, occurred_at:, metadata:)
      return unless version

      ranges = DiffSnapshotRanges.changed_ranges_for(version)
      return if ranges.empty?

      ranges.each do |range|
        upsert_event(
          repository: repository,
          user: user,
          diff_review_version: version,
          source_type: "job_approval",
          engagement_kind: "approved",
          evidence_type: evidence_type,
          evidence_id: evidence_id,
          evidence_key: evidence_key,
          occurred_at: occurred_at,
          base_sha: version.base_sha,
          head_sha: version.head_sha,
          path: range.path,
          side: range.side,
          start_line: range.start_line,
          end_line: range.end_line,
          weight: APPROVAL_WEIGHT,
          confidence: APPROVAL_CONFIDENCE,
          quality: "rubber_stamp",
          metadata: metadata.merge("range_source" => "diff_review_version_files_snapshot")
        )
        yield
      end
    end

    def reviewed_version_for(job, occurred_at)
      versions = job.diff_review_versions.reviewable_for(job).order(created_at: :desc, id: :desc)
      versions.where("created_at <= ?", occurred_at).first || versions.first
    end

    def ingest_pr_review_comments
      scope = PrReviewComment.joins(:job)
        .where(jobs: { repository_id: repository.id })
        .includes(:job)

      scope.find_each do |comment|
        user = user_for_github_handle(comment.github_handle)
        next unless user

        anchor = recover_pr_anchor(comment)
        next unless anchor

        version = reviewed_version_for(comment.job, comment.comment_created_at || comment.created_at)
        upsert_event(
          repository: repository,
          user: user,
          diff_review_version: version,
          source_type: "pr_review_comment",
          engagement_kind: "discussed",
          evidence_type: "PrReviewComment",
          evidence_id: comment.id,
          evidence_key: "pr_review_comment:#{comment.id}",
          occurred_at: comment.comment_created_at || comment.created_at,
          base_sha: version&.base_sha,
          head_sha: version&.head_sha,
          anchor_kind: anchor.anchor_kind,
          path: anchor.path,
          side: anchor.side,
          start_line: anchor.start_line,
          end_line: anchor.end_line,
          confidence: PR_COMMENT_CONFIDENCE,
          quality: "normal",
          metadata: {
            "comment_kind" => comment.comment_kind,
            "pr_type" => comment.pr_type,
            "github_comment_id" => comment.github_comment_id,
            "anchor_recovered_from" => "body"
          }
        )
        result.pr_review_comments += 1
      end
    end

    def recover_pr_anchor(comment)
      body = comment.body.to_s
      version = reviewed_version_for(comment.job, comment.comment_created_at || comment.created_at)
      paths = Array(version&.files_snapshot).filter_map { |file| file["path"] || file[:path] }
      paths.each do |path|
        escaped = Regexp.escape(path)
        if (match = body.match(/#{escaped}(?:#L|:)(?<line>\d+)/))
          line = match[:line].to_i
          return PrAnchor.new(path: path, side: "right", start_line: line, end_line: line, anchor_kind: "range")
        end

        return PrAnchor.new(path: path, side: nil, start_line: nil, end_line: nil, anchor_kind: "file") if body.include?(path)
      end

      nil
    end

    def ingest_human_authored_commits
      source = commit_source || HumanCommitSource.new(repository: repository)
      classifier = HumanAuthorClassifier.new(repository)
      source.each_commit do |commit|
        user = classifier.user_for(commit)
        next unless user

        commit.files.each do |file|
          next if file.path.blank?

          upsert_event(
            repository: repository,
            user: user,
            source_type: "authored_line",
            engagement_kind: "authored",
            evidence_type: "GitCommit",
            evidence_id: nil,
            evidence_key: "git_commit:#{commit.sha}:#{file.path}",
            occurred_at: commit.authored_at,
            commit_sha: commit.sha,
            anchor_kind: "file",
            path: file.path,
            confidence: BigDecimal("0.9"),
            quality: "high",
            metadata: {
              "author_name" => commit.author_name,
              "author_email" => commit.author_email,
              "additions" => file.additions,
              "deletions" => file.deletions
            }
          )
          result.authored_commits += 1
        end
      end
    rescue GitRunner::GitError => e
      Rails.logger.warn(
        "[CognitiveEngagementEvents::SourceIngestor] could not ingest git history for " \
        "#{repository.slug}: #{e.class}: #{e.message}"
      )
    end

    def user_for_github_handle(handle)
      normalized = handle.to_s.downcase.strip
      return nil if normalized.blank?

      User.where("LOWER(github_handle) = ?", normalized).first
    end

    def upsert_event(**attributes)
      Upsert.call(**attributes)
    end
  end
end
