class AddPollStatusToRepositories < ActiveRecord::Migration[8.1]
  def change
    add_column :repositories, :last_poll_started_at, :datetime
    add_column :repositories, :last_poll_status, :string
    add_column :repositories, :last_poll_error, :text
  end
end
