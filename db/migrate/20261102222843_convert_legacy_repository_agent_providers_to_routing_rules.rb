# Converts the legacy repositories.agent_provider and
# repository_memberships.agent_provider pins into ProviderRoutingRules before
# the columns are dropped. See ProviderRouting::LegacyProviderConversion for the
# mapping and the deliberately skipped pins (logged below).
class ConvertLegacyRepositoryAgentProvidersToRoutingRules < ActiveRecord::Migration[8.1]
  def up
    return unless column_exists?(:repositories, :agent_provider)
    return unless table_exists?(:provider_routing_rules)

    repository_rows = select_all("SELECT id, owner, name, user_id, agent_provider FROM repositories WHERE agent_provider IS NOT NULL AND agent_provider <> ''").map(&:symbolize_keys)
    membership_rows = if column_exists?(:repository_memberships, :agent_provider)
      select_all("SELECT repository_id, user_id, role, agent_provider FROM repository_memberships WHERE agent_provider IS NOT NULL AND agent_provider <> ''").map(&:symbolize_keys)
    else
      []
    end
    ProviderRoutingRule.reset_column_information

    result = ProviderRouting::LegacyProviderConversion.call(
      repository_rows: repository_rows,
      membership_rows: membership_rows,
      logger: ->(message) { say(message, true) }
    )
    say("legacy provider conversion: #{result.converted.size} converted, #{result.skipped.size} skipped, #{result.warnings.size} warnings", true)
  end

  def down
    # Irreversible by design: the converted rules are ordinary routing rules and
    # the original column values are not recoverable once dropped.
  end
end
