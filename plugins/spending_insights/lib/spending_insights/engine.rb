module SpendingInsights
  class Engine < ::Rails::Engine
    config.to_prepare do
      unless SpendingInsights::ChatToolSet < Syrus::Plugin::ChatMcpToolSet
        SpendingInsights::ChatToolSet.include(Syrus::Plugin::ChatMcpToolSet)
      end

      SpendingInsights.register!
    end
  end
end
