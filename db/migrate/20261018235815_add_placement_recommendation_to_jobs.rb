class AddPlacementRecommendationToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :placement_recommendation, :json unless column_exists?(:jobs, :placement_recommendation)
    add_column :jobs, :placement_recommendation_status, :string unless column_exists?(:jobs, :placement_recommendation_status)
  end
end
