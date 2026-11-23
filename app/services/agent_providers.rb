module AgentProviders
  class ConfigurationError < StandardError; end

  def self.for(provider)
    klass = PerformanceLogging.phase("agent_providers.lookup", provider: provider) do
      Syrus::Plugin::ServiceProvider.providers(:agent_provider)
        .find do |p|
          Syrus::PluginInvocation.value(Syrus::PluginInvocation.call(
            extension_point: :agent_provider, provider: p, operation: :provider_key, on_decline: false
          ) do
            p.provider_key == provider.to_s
          end)
        end
    end
    unless klass
      raise ConfigurationError, "Unknown agent provider: #{provider.inspect}"
    end

    klass
  end

  # Runs a one-shot (no MCP, no workflow context) agent invocation.
  # scope names the tmpdir prefix and the Codex agent_home sub-path.
  def self.run_one_shot(provider:, user:, runner:, scope:, prompt:, log_sink:, timeout:, max_turns:, agent: nil, job: nil)
    Dir.mktmpdir("syrus-#{scope}") do |workspace_path|
      prior_agent = Thread.current[:syrus_current_agent]
      prior_job = Thread.current[:syrus_current_job]
      klass = self.for(provider)
      Thread.current[:syrus_current_agent] = agent if agent
      Thread.current[:syrus_current_job] = job if job
      result = Syrus::PluginInvocation.call(extension_point: :agent_provider, provider: klass, operation: :invoke_one_shot, on_decline: nil) do
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
      return Syrus::PluginInvocation.value(result) unless result.is_a?(Syrus::PluginInvocation::Failed)

      raise ConfigurationError, result.message
    ensure
      Thread.current[:syrus_current_agent] = prior_agent
      Thread.current[:syrus_current_job] = prior_job
    end
  end
end
