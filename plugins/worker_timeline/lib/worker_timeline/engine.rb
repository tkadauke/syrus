module WorkerTimeline
  class Engine < ::Rails::Engine
    config.to_prepare do
      WorkerTimeline.register!
    end
  end
end
