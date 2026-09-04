module App
  class DiffReviewCommentsPayload
    def self.build(job:, comments:)
      new(job: job, comments: comments).payload
    end

    def initialize(job:, comments:)
      @job = job
      @comments = comments.to_a
    end

    def payload
      serialized = @comments.map { |comment| comment_json(comment) }

      {
        job_id: @job.id,
        comments: serialized,
        by_path: grouped_by_path(serialized)
      }
    end

    private

    def grouped_by_path(serialized)
      serialized.group_by { |comment| comment[:path] }.transform_values do |path_comments|
        path_comments.group_by { |comment| comment[:anchor_key] }
      end
    end

    def comment_json(comment)
      {
        id: comment.id,
        job_id: comment.job_id,
        user_id: comment.user_id,
        user: user_json(comment.user),
        workflow_id: comment.workflow_id,
        workflow: workflow_json(comment.workflow),
        run_id: comment.run_id,
        surface: comment.surface,
        base_ref: comment.base_ref,
        head_ref: comment.head_ref,
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
  end
end
