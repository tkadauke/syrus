module HomeHelper
  DASHBOARD_COLUMN_LABELS = {
    "epics" => {
      "epic" => "Epic",
      "state" => "State",
      "repository" => "Repository",
      "updated" => "Updated"
    },
    "jobs" => {
      "checkbox" => "Checkbox",
      "issue" => "Issue",
      "state" => "State",
      "repository" => "Repository",
      "latest" => "Latest",
      "workflows_count" => "Workflows count",
      "started" => "Started"
    },
    "workflows" => {
      "workflow" => "Workflow",
      "job" => "Job",
      "trigger" => "Trigger",
      "state" => "State",
      "started" => "Started",
      "finished" => "Finished",
      "agent" => "Agent"
    }
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
end
