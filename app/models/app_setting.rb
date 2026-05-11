class AppSetting < ApplicationRecord
  # Singleton row. .current returns the only record, creating it if missing.
  def self.current
    first || create!
  end

  def self.signups_open?
    current.signups_open
  end

  def self.max_job_failures
    current.max_job_failures
  end

  # Operator-console kill switches. Polling jobs and RunJob check
  # these and short-circuit / re-enqueue when set. Used to halt
  # the system safely during incident response without hard-killing
  # workers.
  def self.polling_paused?
    current.polling_paused
  end

  def self.runs_paused?
    current.runs_paused
  end

  def self.auto_merge_paused?
    ActiveModel::Type::Boolean.new.cast(ENV["SYRUS_AUTO_MERGE_DISABLED"])
  end
end
