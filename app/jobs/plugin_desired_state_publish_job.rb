class PluginDesiredStatePublishJob < ApplicationJob
  queue_as :control_plane

  def perform
    PluginDesiredState::Publisher.publish!
  end
end
