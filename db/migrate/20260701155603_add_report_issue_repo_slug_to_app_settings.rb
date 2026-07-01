class AddReportIssueRepoSlugToAppSettings < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:app_settings, :report_issue_repo_slug)
      add_column :app_settings, :report_issue_repo_slug, :string, default: "tkadauke/syrus", null: false
    end
  end

  def down
    remove_column :app_settings, :report_issue_repo_slug if column_exists?(:app_settings, :report_issue_repo_slug)
  end
end
