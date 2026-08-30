class AddGoalProvenanceForeignKeys < ActiveRecord::Migration[8.1]
  def change
    # Database-level foreign keys are intentionally disabled for Syrus.
    # The provenance columns remain indexed and are enforced through models.
  end
end
