class ResetCoworkerLegacyAuthority < ActiveRecord::Migration[8.1]
  def up
    # Kept empty because some installations recorded this version when it
    # deleted legacy rows. A new migration performs the retry-safe cutover.
  end

  def down; end
end
