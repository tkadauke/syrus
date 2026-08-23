class ExpandRepositoryMembershipRoleTiers < ActiveRecord::Migration[8.1]
  # Conservative default: existing `collaborator` rows only ever granted
  # narrow Epic visibility plus the membership_on_repo?/agent-provider
  # overrides, not Job mutation rights, so they map to the new `read` tier
  # rather than `write`. Existing `owner` rows map to `admin` (the tier that
  # unlocks repository settings/credentials actions the sole FK owner used
  # to have exclusively).
  def up
    execute "UPDATE repository_memberships SET role = 'admin' WHERE role = 'owner'"
    execute "UPDATE repository_memberships SET role = 'read' WHERE role = 'collaborator'"
    change_column_default :repository_memberships, :role, from: "owner", to: "read"
  end

  def down
    change_column_default :repository_memberships, :role, from: "read", to: "owner"
    execute "UPDATE repository_memberships SET role = 'collaborator' WHERE role = 'write'"
    execute "UPDATE repository_memberships SET role = 'owner' WHERE role = 'admin'"
    execute "UPDATE repository_memberships SET role = 'collaborator' WHERE role = 'read'"
  end
end
