# The parameters of the landing blocker an operator overrode (which Job's CI
# repair, which inherited checks, which parent), so a one-shot override binds
# to that one blocker instance and not to every blocker sharing its key.
# Nullable with no default: a parameterless blocker stores NULL (no JSON
# column defaults on MySQL).
class AddLandingBlockerOverrideParamsToJobs < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:jobs, :landing_blocker_override_params)

    add_column :jobs, :landing_blocker_override_params, :json
  end

  def down
    remove_column :jobs, :landing_blocker_override_params if column_exists?(:jobs, :landing_blocker_override_params)
  end
end
