class AddGoalProvenanceForeignKeys < ActiveRecord::Migration[8.1]
  def change
    # Kept as a no-op so deployments that already know this migration version
    # remain consistent while Syrus stores only indexed reference IDs.
  end
end
