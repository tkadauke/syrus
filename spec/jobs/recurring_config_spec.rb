require "rails_helper"

RSpec.describe "recurring job configuration" do
  it "runs the unified merge-state poller every five minutes" do
    config = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
    task = config.fetch("default").fetch("poll_merge_states")
    configured_classes = config.fetch("default").values.filter_map { |entry| entry["class"] }

    expect(task).to include(
      "class" => "PollAllMergeStatesJob",
      "queue" => "polling",
      "schedule" => "every 5 minutes"
    )
    expect(configured_classes).not_to include("PollAllRebasesJob")
  end

  it "polls deployment stages every five minutes" do
    config = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    expect(config.fetch("default").fetch("poll_deployment_stages")).to include(
      "class" => "PollAllDeploymentStagesJob",
      "queue" => "polling",
      "schedule" => "every 5 minutes"
    )
  end

  it "prunes old notifications daily" do
    config = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    expect(config.fetch("default").fetch("prune_old_notifications")).to include(
      "class" => "PruneOldNotificationsJob",
      "queue" => "cleanup",
      "schedule" => "every day at 3:30am"
    )
  end

  it "refreshes workflow step resource profiles hourly" do
    config = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    expect(config.fetch("default").fetch("refresh_workflow_step_resource_profiles")).to include(
      "class" => "WorkflowStepResourceProfileRefreshJob",
      "queue" => "low_priority_maintenance",
      "schedule" => "every hour"
    )
  end

  it "assigns every recurring task to an isolated app queue" do
    config = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
    allowed_queues = %w[control_plane polling indexing cleanup low_priority_maintenance]

    config.fetch("default").each do |key, entry|
      expect(entry["queue"]).to be_present, "#{key} must declare a queue"
      expect(entry["queue"]).to be_in(allowed_queues), "#{key} uses unknown queue #{entry["queue"].inspect}"
    end
  end
end
