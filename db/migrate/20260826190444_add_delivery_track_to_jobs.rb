class AddDeliveryTrackToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :delivery_track, :string unless column_exists?(:jobs, :delivery_track)
  end
end
