# SDLC Pipeline became experimental. An experimental plugin is inert while
# instance beta mode is off, so an instance whose administrator had already
# enabled the plugin would silently lose the Pipeline tab on upgrade. Keep that
# instance working by turning beta mode on for it. Fresh installations and
# instances that never enabled the plugin are untouched. Idempotent.
class GrandfatherSdlcPipelineBetaMode < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:plugin_records) && table_exists?(:app_settings)
    return unless column_exists?(:app_settings, :beta_mode_enabled)

    enabled = select_value("SELECT 1 FROM plugin_records WHERE name = 'sdlc_pipeline' AND enabled = #{quoted_true} LIMIT 1")
    return unless enabled

    execute("UPDATE app_settings SET beta_mode_enabled = #{quoted_true} WHERE beta_mode_enabled = #{quoted_false}")
  end

  def down
    # Irreversible data migration; beta mode is an operator choice.
  end
end
