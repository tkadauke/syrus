class AddFullPollBackstopToRepositoriesAndAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :repositories, :last_full_poll_at, :datetime unless column_exists?(:repositories, :last_full_poll_at)
    add_column :app_settings, :repository_full_poll_interval_hours, :integer, default: 24, null: false unless column_exists?(:app_settings, :repository_full_poll_interval_hours)
  end
end
