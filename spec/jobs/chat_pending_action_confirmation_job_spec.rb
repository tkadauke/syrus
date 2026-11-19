require "rails_helper"
require "erb"
require "yaml"

# A confirmation is an operator waiting on a spinner. On the control_plane
# queue it waited behind reconciler sweeps and domain-event bursts for one to
# two minutes, and a long confirmation held a scheduler thread for its whole
# run, so it has a lane of its own.
RSpec.describe ChatPendingActionConfirmationJob do
  it "runs on the operator_actions lane, not control_plane" do
    expect(described_class.new.queue_name).to eq("operator_actions")
  end

  it "has a worker for that lane in every deployment shape" do
    %w[config/queue.yml config/queue.home.yml].each do |path|
      config = YAML.safe_load(ERB.new(Rails.root.join(path).read).result, aliases: true)
      queues = Array(config.dig("default", "workers")).flat_map { |worker| Array(worker["queues"]) }

      expect(queues).to include("operator_actions"), path
    end
  end
end
