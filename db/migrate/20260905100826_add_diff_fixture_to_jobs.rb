class AddDiffFixtureToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :diff_fixture, :json unless column_exists?(:jobs, :diff_fixture)
  end
end
