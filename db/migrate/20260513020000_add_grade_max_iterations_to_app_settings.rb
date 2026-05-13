class AddGradeMaxIterationsToAppSettings < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:app_settings, :grade_max_iterations)

    add_column :app_settings, :grade_max_iterations, :integer, default: 5, null: false
  end
end
