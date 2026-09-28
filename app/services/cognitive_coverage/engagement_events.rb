require_dependency "cognitive_coverage/snapshot"

module CognitiveCoverage
  class EngagementEvents
    def self.for(repository)
      new(repository).call
    end

    def initialize(repository)
      @repository = repository
    end

    def call
      diff_review_comment_events + pr_review_comment_events + approval_events
    end

    private

    def diff_review_comment_events
      DiffReviewComment
        .joins(:job, :diff_review_version)
        .where(jobs: { repository_id: @repository.id })
        .where.not(state: "draft")
        .where(anchor_kind: "line")
        .filter_map do |comment|
          line = comment.new_line || comment.old_line
          next unless comment.path.present? && line.present?

          Engagement.new(
            path: comment.path,
            line_number: line,
            engaged_at: engagement_time(comment),
            source: "diff_review_comment",
            source_sha: comment.diff_review_version.head_sha
          )
        end
    end

    def pr_review_comment_events
      PrReviewComment
        .joins(:job)
        .where(jobs: { repository_id: @repository.id })
        .where.not(path: nil)
        .filter_map do |comment|
          line = comment.anchor_line
          next unless line.present?

          Engagement.new(
            path: comment.path,
            line_number: line,
            engaged_at: comment.created_at,
            source: "pr_review_comment",
            source_sha: nil
          )
        end
    end

    def approval_events
      approval_rows.flat_map do |job, approved_at|
        next [] unless approved_at

        job.diff_review_versions.flat_map do |version|
          Array(version.files_snapshot).filter_map do |file|
            path = file["path"].presence
            next unless path

            Engagement.new(
              path: path,
              line_number: nil,
              engaged_at: approved_at,
              source: "job_approval",
              source_sha: version.head_sha
            )
          end
        end
      end
    end

    def approval_rows
      jobs = Job.where(repository: @repository).includes(:diff_review_versions)
      explicit = JobApproval.joins(:job).where(jobs: { repository_id: @repository.id }).includes(job: :diff_review_versions)
      rows = explicit.map { |approval| [ approval.job, approval.approved_at ] }
      rows + jobs.where.not(approved_at: nil).map { |job| [ job, job.approved_at ] }
    end

    def engagement_time(comment)
      [ comment.resolved_at, comment.submitted_at, comment.created_at ].compact.max
    end
  end
end
