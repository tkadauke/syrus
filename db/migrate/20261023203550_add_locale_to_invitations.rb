class AddLocaleToInvitations < ActiveRecord::Migration[8.1]
  def up
    add_column :invitations, :locale, :string unless column_exists?(:invitations, :locale)
    execute "UPDATE invitations SET locale = 'en' WHERE locale IS NULL"
    change_column_null :invitations, :locale, false if column_exists?(:invitations, :locale)
  end

  def down
    remove_column :invitations, :locale if column_exists?(:invitations, :locale)
  end
end
