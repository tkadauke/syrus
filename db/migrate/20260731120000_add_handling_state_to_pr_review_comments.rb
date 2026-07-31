class AddHandlingStateToPrReviewComments < ActiveRecord::Migration[8.1]
  class MigrationWorkflow < ActiveRecord::Base
    self.table_name = "workflows"
  end

  class MigrationPrReviewComment < ActiveRecord::Base
    self.table_name = "pr_review_comments"
  end

  def up
    unless column_exists?(:pr_review_comments, :handling_workflow_id)
      add_reference :pr_review_comments, :handling_workflow, foreign_key: { to_table: :workflows }
    end
    add_column :pr_review_comments, :handling_state, :string unless column_exists?(:pr_review_comments, :handling_state)
    add_column :pr_review_comments, :handling_started_at, :datetime unless column_exists?(:pr_review_comments, :handling_started_at)
    add_column :pr_review_comments, :handling_failed_at, :datetime unless column_exists?(:pr_review_comments, :handling_failed_at)
    add_column :pr_review_comments, :handling_failure_reason, :string unless column_exists?(:pr_review_comments, :handling_failure_reason)
    add_column :pr_review_comments, :handled_at, :datetime unless column_exists?(:pr_review_comments, :handled_at)
    add_column :pr_review_comments, :ignored_at, :datetime unless column_exists?(:pr_review_comments, :ignored_at)

    add_index :pr_review_comments, :handling_state unless index_exists?(:pr_review_comments, :handling_state)

    backfill_failed_feedback_handling!
  end

  def down
    remove_index :pr_review_comments, :handling_state if index_exists?(:pr_review_comments, :handling_state)
    remove_reference :pr_review_comments, :handling_workflow, foreign_key: { to_table: :workflows } if column_exists?(:pr_review_comments, :handling_workflow_id)
    remove_column :pr_review_comments, :handling_state if column_exists?(:pr_review_comments, :handling_state)
    remove_column :pr_review_comments, :handling_started_at if column_exists?(:pr_review_comments, :handling_started_at)
    remove_column :pr_review_comments, :handling_failed_at if column_exists?(:pr_review_comments, :handling_failed_at)
    remove_column :pr_review_comments, :handling_failure_reason if column_exists?(:pr_review_comments, :handling_failure_reason)
    remove_column :pr_review_comments, :handled_at if column_exists?(:pr_review_comments, :handled_at)
    remove_column :pr_review_comments, :ignored_at if column_exists?(:pr_review_comments, :ignored_at)
  end

  private

  def backfill_failed_feedback_handling!
    say_with_time "Backfilling failed PR feedback handling state" do
      MigrationWorkflow.where(trigger_kind: %w[pr_comment chat_feedback], state: "failed").find_each do |workflow|
        source_comments_for(workflow).each do |comment|
          next if comment.ignored_at.present? || comment.handled_at.present?

          comment.update!(
            handling_workflow_id: workflow.id,
            handling_state: "failed",
            handling_started_at: workflow.created_at,
            handling_failed_at: workflow.finished_at || workflow.updated_at,
            handling_failure_reason: "workflow_failed",
            actioned_at: nil
          )
        end
      end
    end
  end

  def source_comments_for(workflow)
    artifacts = parse_artifacts(workflow.artifacts)
    source_id = artifacts.dig("feedback_source", "pr_review_comment_id").to_i
    return MigrationPrReviewComment.where(id: source_id).to_a if source_id.positive?

    comments = Array(artifacts["pr_comments"])
    return [] if comments.empty?

    comments.filter_map do |artifact|
      MigrationPrReviewComment.find_by(
        job_id: workflow.job_id,
        github_handle: artifact["author"],
        body: artifact["body"],
        comment_created_at: parse_time(artifact["created_at"])
      )
    end
  end

  def parse_artifacts(value)
    JSON.parse(value.presence || "{}")
  rescue JSON::ParserError
    {}
  end

  def parse_time(value)
    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end
end
