module ScheduledTasksHelper
  STATE_STYLES = {
    "scheduled"   => "bg-green-100 text-green-700",
    "paused"      => "bg-gray-100 text-gray-600",
    "auto_paused" => "bg-red-100 text-red-700",
    "fired"       => "bg-blue-100 text-blue-700"
  }.freeze

  def scheduled_task_state_pill(task)
    colored_pill(task.state, classes: STATE_STYLES[task.state] || ApplicationHelper::PILL_FALLBACK_CLASSES)
  end

  def auto_approve_mode_options
    [
      [ "Never", "never" ],
      [ "If graders pass", "if_graders_pass" ],
      [ "If graders pass and tagged safe", "if_graders_pass_and_tagged_safe" ]
    ]
  end

  def auto_approve_preview(record)
    case record.auto_approve_mode
    when "if_graders_pass"
      "Jobs using this rule enter landing after repo-committed graders pass."
    when "if_graders_pass_and_tagged_safe"
      "Jobs using this rule also need the safe tag before landing."
    else
      "No direct rule; Jobs can still inherit a repository or user default."
    end
  end
end
