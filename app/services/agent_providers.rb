module AgentProviders
  class ConfigurationError < StandardError; end

  def self.for(provider)
    klass = PerformanceLogging.phase("agent_providers.lookup", provider: provider) do
      Syrus::PluginRegistry.providers_for(:agent_provider)
        .find do |p|
          PerformanceLogging.plugin_call(extension_point: :agent_provider, provider: p, operation: :provider_key) do
            p.provider_key == provider.to_s
          end
        end
    end
    unless klass
      raise ConfigurationError, "Unknown agent provider: #{provider.inspect}"
    end

    klass
  end

  # Runs a one-shot (no MCP, no workflow context) agent invocation.
  # scope names the tmpdir prefix and the Codex agent_home sub-path.
  def self.run_one_shot(provider:, user:, runner:, scope:, prompt:, log_sink:, timeout:, max_turns:, agent: nil)
    Dir.mktmpdir("syrus-#{scope}") do |workspace_path|
      prior_agent = Thread.current[:syrus_current_agent]
      klass = self.for(provider)
      Thread.current[:syrus_current_agent] = agent if agent
      PerformanceLogging.plugin_call(extension_point: :agent_provider, provider: klass, operation: :invoke_one_shot) do
        klass.invoke_one_shot(
          workspace_path: workspace_path,
          user: user,
          runner: runner,
          scope: scope,
          prompt: prompt,
          log_sink: log_sink,
          timeout: timeout,
          max_turns: max_turns
        )
      end
    ensure
      Thread.current[:syrus_current_agent] = prior_agent
    end
  end
end
