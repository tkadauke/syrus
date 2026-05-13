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
end
