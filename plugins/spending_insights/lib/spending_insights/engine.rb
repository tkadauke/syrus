module SpendingInsights
  class Engine < ::Rails::Engine
    config.after_initialize do
      SpendingInsights.register!
    end
  end
end
