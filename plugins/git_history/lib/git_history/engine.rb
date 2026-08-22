module GitHistory
  class Engine < ::Rails::Engine
    config.after_initialize do
      GitHistory.register!
    end
  end
end
