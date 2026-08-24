class AddPayloadArtifactsToWorkIntents < ActiveRecord::Migration[8.1]
  def change
    add_column :work_intents, :payload_artifacts, :json, if_not_exists: true
  end
end
