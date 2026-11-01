class ResetCoworkerLegacyAuthority < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:coworker_grants)

    # Unified descriptor defaults are now the source of coworker authority.
    # Keeping these rows would preserve the broader, pre-cutover grant set in
    # diagnostics and invite a future caller to treat it as active authority.
    execute "DELETE FROM coworker_grants"
  end

  def down; end
end
