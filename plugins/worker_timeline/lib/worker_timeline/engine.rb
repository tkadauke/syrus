module WorkerTimeline
  class Engine < ::Rails::Engine
    config.after_initialize do
      WorkerTimeline.register!
    end
  end
end
