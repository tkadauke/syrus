module App
  class DiffReviewCommentsPayload
    def self.build(job:, comments:, version: nil)
      new(job: job, comments: comments, version: version).payload
    end

    def initialize(job:, comments:, version:)
      @job = job
      @comments = comments.to_a
      @version = version
    end

    def payload
      {
        job_id: @job.id,
        diff_review_version_id: @version&.id,
        latest_version_id: DiffReviewVersion.default_for_review(@job)&.id,
        diff_review_version: diff_review_version_json(@version),
        users: @comments.filter_map(&:user).uniq(&:id).to_h { |user| [ user.id, user_json(user) ] },
        workflows: @comments.filter_map(&:workflow).uniq(&:id).to_h { |workflow| [ workflow.id, workflow_json(workflow) ] },
        comments: @comments.map { |comment| comment_json(comment) }
      }
    end

    private

    def comment_json(comment)
      {
        id: comment.id,
        job_id: comment.job_id,
        diff_review_version_id: comment.diff_review_version_id,
        parent_id: comment.parent_id,
        user_id: comment.user_id,
        workflow_id: comment.workflow_id,
        run_id: comment.run_id,
        surface: comment.surface,
        base_ref: comment.base_ref,
        head_ref: comment.head_ref,
        anchor_kind: comment.anchor_kind,
        path: comment.path,
        side: comment.side,
        old_line: comment.old_line,
        new_line: comment.new_line,
        anchor_key: comment.anchor_key,
        diff_hunk: comment.diff_hunk,
        context: comment.context || {},
        body: comment.body,
        state: comment.state,
        created_at: comment.created_at&.iso8601,
        updated_at: comment.updated_at&.iso8601,
        submitted_at: comment.submitted_at&.iso8601,
        resolved_at: comment.resolved_at&.iso8601,
        superseded_at: comment.superseded_at&.iso8601
      }
    end

    def user_json(user)
      return nil unless user

      {
        id: user.id,
        display_name: user.display_name,
        email_address: user.email_address,
        avatar_url: user.avatar_url
      }
    end

    def workflow_json(workflow)
      return nil unless workflow

      {
        id: workflow.id,
        trigger_kind: workflow.trigger_kind,
        state: workflow.state
      }
    end

    def diff_review_version_json(version)
      return nil unless version

      {
        id: version.id,
        version_index: version.version_index,
        base_sha: version.base_sha,
        head_sha: version.head_sha,
        base_ref: version.base_ref,
        head_ref: version.head_ref,
        trigger_kind: version.trigger_kind,
        label: version.label,
        reason: version.reason
      }
    end
  end
end
