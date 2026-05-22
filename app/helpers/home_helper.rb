module HomeHelper
  DASHBOARD_COLUMN_LABELS = {
    "epics" => {
      "epic" => "Epic",
      "state" => "State",
      "repository" => "Repository",
      "updated" => "Updated",
      "created_at" => "Created at",
      "updated_at" => "Updated at",
      "done_at" => "Done at",
      "archived_at" => "Archived at"
    },
    "jobs" => {
      "checkbox" => "Checkbox",
      "issue" => "Issue",
      "state" => "State",
      "repository" => "Repository",
      "latest" => "Latest",
      "workflows_count" => "Workflows count",
      "started" => "Started",
      "created_at" => "Created at",
      "updated_at" => "Updated at",
      "started_at" => "Started at",
      "finished_at" => "Finished at",
      "approved_at" => "Approved at",
      "dependencies_overridden_at" => "Dependencies overridden at",
      "last_feedback_addressed_at" => "Last feedback addressed at",
      "last_seen_comment_at" => "Last seen comment at",
      "pr_mergeable_checked_at" => "PR mergeable checked at"
    },
    "workflows" => {
      "workflow" => "Workflow",
      "job" => "Job",
      "trigger" => "Trigger",
      "state" => "State",
      "started" => "Started",
      "finished" => "Finished",
      "agent" => "Agent",
      "created_at" => "Created at",
      "updated_at" => "Updated at",
      "started_at" => "Started at",
      "finished_at" => "Finished at",
      "cleaned_up_at" => "Cleaned up at"
    }
  }.freeze
  DASHBOARD_TIMESTAMP_COLUMNS = {
    "epics" => %w[created_at updated_at done_at archived_at],
    "jobs" => %w[
      created_at updated_at started_at finished_at approved_at
      dependencies_overridden_at last_feedback_addressed_at
      last_seen_comment_at pr_mergeable_checked_at
    ],
    "workflows" => %w[created_at updated_at started_at finished_at cleaned_up_at]
  }.freeze

  def dashboard_column_visible?(subject, column)
    Current.user.dashboard_visible_columns(subject).include?(column.to_s)
  end

  def dashboard_required_columns(subject)
    User::DASHBOARD_REQUIRED_COLUMNS.fetch(subject.to_s)
  end

  def dashboard_optional_columns(subject)
    User::DASHBOARD_OPTIONAL_COLUMNS.fetch(subject.to_s)
  end

  def dashboard_column_label(subject, column)
    DASHBOARD_COLUMN_LABELS.dig(subject.to_s, column.to_s) || column.to_s.humanize
  end

  def dashboard_timestamp_columns(subject)
    DASHBOARD_TIMESTAMP_COLUMNS.fetch(subject.to_s)
  end
end
