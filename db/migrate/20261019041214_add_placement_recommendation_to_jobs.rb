class AddPlacementRecommendationToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :placement_recommendation, :json
    add_column :jobs, :placement_recommendation_status, :string
    add_column :jobs, :placement_recommendation_decided_at, :datetime
    add_reference :jobs, :placement_recommendation_decided_by_user, foreign_key: { to_table: :users }
  end
end
