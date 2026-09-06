class AddTriagingUncertaintyToJobs < ActiveRecord::Migration[8.1]
  # Why the classifier gave up used to go to Rails.logger.warn and nowhere
  # else, so a Job stuck in `triaging / classifier_uncertain` carried no record
  # of what went wrong. By the time anyone noticed (JOB-3184 sat for three
  # weeks) the logs were long gone, and "retry it" and "a human must read this"
  # are indistinguishable without that reason.
  def up
    add_column :jobs, :triaging_uncertainty_reason, :text unless column_exists?(:jobs, :triaging_uncertainty_reason)
    add_column :jobs, :classifier_attempts, :integer, default: 0, null: false unless column_exists?(:jobs, :classifier_attempts)
  end

  def down
    remove_column :jobs, :triaging_uncertainty_reason if column_exists?(:jobs, :triaging_uncertainty_reason)
    remove_column :jobs, :classifier_attempts if column_exists?(:jobs, :classifier_attempts)
  end
end
