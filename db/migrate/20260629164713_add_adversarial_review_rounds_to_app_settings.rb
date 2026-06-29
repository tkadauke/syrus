class AddAdversarialReviewRoundsToAppSettings < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:app_settings, :adversarial_review_rounds)
      add_column :app_settings, :adversarial_review_rounds, :integer, default: 0, null: false
    end
  end

  def down
    remove_column :app_settings, :adversarial_review_rounds if column_exists?(:app_settings, :adversarial_review_rounds)
  end
end
