require "rails_helper"

RSpec.describe "recurring job configuration" do
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

  it "polls deployment stages every five minutes" do
    config = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    expect(config.fetch("default").fetch("poll_deployment_stages")).to include(
      "class" => "PollAllDeploymentStagesJob",
      "schedule" => "every 5 minutes"
    )
  end

  it "prunes old notifications daily" do
    config = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    expect(config.fetch("default").fetch("prune_old_notifications")).to include(
      "class" => "PruneOldNotificationsJob",
      "schedule" => "every day at 3:30am"
    )
  end
end
