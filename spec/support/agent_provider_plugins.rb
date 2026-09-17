# claude_agent, codex_agent, and agy_agent are now default_enabled: false so
# a freshly onboarded production instance starts with no agent provider
# connected until an admin opts one in from Admin -> Plugins (see
# plugins/claude_agent/lib/claude_agent.rb, plugins/codex_agent/lib/codex_agent.rb,
# plugins/agy_agent/lib/agy_agent.rb).
#
# The test suite is not modeling that onboarding moment -- `bin/rails
# db:test:prepare` truncates plugin_records ahead of every rspec-fast run, so
# every worker's first boot is a "fresh install" that would otherwise create
# these PluginRecord rows disabled. The overwhelming majority of the suite
# assumes at least Claude and Codex are already connected (User#agent_provider
# defaults to "claude" at the schema level), so leaving them disabled here
# would fail almost everything with a false
# `AgentProviders::ConfigurationError` instead of exercising real behavior.
#
# A spec that needs to assert what a genuinely fresh, nothing-connected
# instance looks like does that explicitly against the registry/upsert
# mechanics directly (see spec/lib/syrus/plugin_registry_spec.rb); this
# mirrors the existing per-spec pattern used to opt `muse_agent` in where its
# behavior is under test.
RSpec.configure do |config|
  config.before(:suite) do
    PluginRecord.where(name: %w[claude_agent codex_agent agy_agent]).find_each do |record|
      record.update!(enabled: true) unless record.enabled?
    end
  end
end
