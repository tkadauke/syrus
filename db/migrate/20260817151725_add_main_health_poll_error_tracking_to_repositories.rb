class AddMainHealthPollErrorTrackingToRepositories < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:repositories, :main_health_poll_error_streak)
      add_column :repositories, :main_health_poll_error_streak, :integer, null: false, default: 0
    end
    unless column_exists?(:repositories, :last_main_health_poll_error_at)
      add_column :repositories, :last_main_health_poll_error_at, :datetime
    end
  end

  def down
    if column_exists?(:repositories, :last_main_health_poll_error_at)
      remove_column :repositories, :last_main_health_poll_error_at
    end
    if column_exists?(:repositories, :main_health_poll_error_streak)
      remove_column :repositories, :main_health_poll_error_streak
    end
  end
end
