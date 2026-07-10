module AgentProviders
  class ConfigurationError < StandardError; end

  def self.for(provider)
    klass = Syrus::PluginRegistry.providers_for(:agent_provider)
              .find { |p| p.provider_key == provider.to_s }
    unless klass
      raise ConfigurationError, "Unknown agent provider: #{provider.inspect}"
    end

    klass
  end

  # Runs a one-shot (no MCP, no workflow context) agent invocation.
  # scope names the tmpdir prefix and the Codex agent_home sub-path.
  def self.run_one_shot(provider:, user:, runner:, scope:, prompt:, log_sink:, timeout:, max_turns:)
    Dir.mktmpdir("syrus-#{scope}") do |workspace_path|
      self.for(provider).invoke_one_shot(
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
  end
end
