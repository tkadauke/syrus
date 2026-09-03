module TestInsights
  class Engine < ::Rails::Engine
    config.to_prepare do
      TestInsights::HostAssociations.apply!
    end

    config.after_initialize do
      unless TestInsights::McpToolSet < Syrus::Plugin::McpToolSet
        TestInsights::McpToolSet.include(Syrus::Plugin::McpToolSet)
      end

      unless TestInsights::ChatToolSet < Syrus::Plugin::ChatMcpToolSet
        TestInsights::ChatToolSet.include(Syrus::Plugin::ChatMcpToolSet)
      end

      Object.const_set(:TestRun, TestInsights::TestRun) unless Object.const_defined?(:TestRun)
      Object.const_set(:TestCase, TestInsights::TestCase) unless Object.const_defined?(:TestCase)

      TestInsights.register!
    end
  end
end
