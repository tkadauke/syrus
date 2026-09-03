module SpendingInsights
  class Engine < ::Rails::Engine
    config.after_initialize do
      unless SpendingInsights::ChatToolSet < Syrus::Plugin::ChatMcpToolSet
        SpendingInsights::ChatToolSet.include(Syrus::Plugin::ChatMcpToolSet)
      end

      SpendingInsights.register!
    end
  end
end
