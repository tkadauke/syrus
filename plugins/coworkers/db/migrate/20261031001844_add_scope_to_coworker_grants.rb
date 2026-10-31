class AddScopeToCoworkerGrants < ActiveRecord::Migration[8.1]
  def change
    add_column :coworker_grants, :scope, :json unless column_exists?(:coworker_grants, :scope)
  end
end
