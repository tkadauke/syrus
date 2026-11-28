# The worker environment smoke checks a repository's prepare plan needs
# (bundler, a C toolchain, a MySQL client, ...), recorded when a workspace for
# it is prepared so routing can keep it off workers that fail those checks.
# No database default: MySQL rejects JSON column defaults.
class AddWorkerEnvironmentRequirementsToRepositories < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:repositories, :worker_environment_requirements)

    add_column :repositories, :worker_environment_requirements, :json
  end

  def down
    remove_column :repositories, :worker_environment_requirements if column_exists?(:repositories, :worker_environment_requirements)
  end
end
