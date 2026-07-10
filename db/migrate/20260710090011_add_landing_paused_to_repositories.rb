class AddLandingPausedToRepositories < ActiveRecord::Migration[8.1]
  def up
    add_column :repositories, :landing_paused, :boolean, default: false, null: false unless column_exists?(:repositories, :landing_paused)
    add_index :repositories, :landing_paused unless index_exists?(:repositories, :landing_paused)
  end

  def down
    remove_index :repositories, :landing_paused if index_exists?(:repositories, :landing_paused)
    remove_column :repositories, :landing_paused if column_exists?(:repositories, :landing_paused)
  end
end
