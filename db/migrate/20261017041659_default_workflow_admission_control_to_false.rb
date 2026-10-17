class DefaultWorkflowAdmissionControlToFalse < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:app_settings)
    return unless column_exists?(:app_settings, :workflow_admission_control_enabled)
    return if column_default == false

    change_column_default :app_settings, :workflow_admission_control_enabled, false
  end

  def down
    return unless table_exists?(:app_settings)
    return unless column_exists?(:app_settings, :workflow_admission_control_enabled)
    return if column_default == true

    change_column_default :app_settings, :workflow_admission_control_enabled, true
  end

  private

  def column_default
    raw_default = connection.columns(:app_settings)
      .find { |column| column.name == "workflow_admission_control_enabled" }
      &.default
    ActiveModel::Type::Boolean.new.cast(raw_default)
  end
end
