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

  it "runs the unified merge-state poller every five minutes" do
    config = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
    task = config.fetch("default").fetch("poll_merge_states")
    configured_classes = config.fetch("default").values.filter_map { |entry| entry["class"] }

    expect(task).to include(
      "class" => "PollAllMergeStatesJob",
      "schedule" => "every 5 minutes"
    )
    expect(configured_classes).not_to include("PollAllRebasesJob")
  end

end
