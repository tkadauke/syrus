class ChangePollingEnabledDefaultToTrue < ActiveRecord::Migration[8.1]
  def change
    change_column_default :repositories, :polling_enabled, from: false, to: true
  end
end
