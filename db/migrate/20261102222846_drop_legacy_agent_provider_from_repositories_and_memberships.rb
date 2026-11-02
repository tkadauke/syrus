# Follow-up to the routing-rule conversion: routing rules are now the only way
# to choose a provider per repository. Kept as its own migration so it is easy
# to revert independently.
class DropLegacyAgentProviderFromRepositoriesAndMemberships < ActiveRecord::Migration[8.1]
  def up
    remove_column :repositories, :agent_provider if column_exists?(:repositories, :agent_provider)
    remove_column :repository_memberships, :agent_provider if column_exists?(:repository_memberships, :agent_provider)
  end

  def down
    add_column :repositories, :agent_provider, :string unless column_exists?(:repositories, :agent_provider)
    add_column :repository_memberships, :agent_provider, :string unless column_exists?(:repository_memberships, :agent_provider)
  end
end
