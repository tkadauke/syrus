require "rails_helper"

RSpec.describe "recurring job configuration" do
  it "runs ReapAwaitingOperatorRunsJob hourly" do
    config = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
    task = config.fetch("default").fetch("reap_awaiting_operator_runs")

    expect(task).to include(
      "class" => "ReapAwaitingOperatorRunsJob",
      "schedule" => "every hour"
    )
  end

  it "runs OperatorQuestionNudgeJob hourly" do
    config = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
    task = config.fetch("default").fetch("nudge_awaiting_operator_runs")

    expect(task).to include(
      "class" => "OperatorQuestionNudgeJob",
      "schedule" => "every hour"
    )
  end

  it "runs RecurringTaskTickJob every minute" do
    config = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
    task = config.fetch("default").fetch("recurring_task_tick")

    expect(task).to include(
      "class" => "RecurringTaskTickJob",
      "schedule" => "every minute"
    )
  end
end
