class AddSecurityReviewRoundsToAppSettings < ActiveRecord::Migration[8.1]
  def up
    add_column :app_settings, :security_review_rounds, :integer, default: 0, null: false unless column_exists?(:app_settings, :security_review_rounds)
  end

  def down
    remove_column :app_settings, :security_review_rounds if column_exists?(:app_settings, :security_review_rounds)
  end
end
