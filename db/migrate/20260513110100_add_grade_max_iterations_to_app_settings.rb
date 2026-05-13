class AddGradeMaxIterationsToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :grade_max_iterations, :integer, default: 5, null: false
  end
end
