module AlertmanagerInvestigations
  class Investigation < ApplicationRecord
    self.table_name = "alertmanager_investigations"

    belongs_to :job, optional: true
    belongs_to :repository, optional: true

    validates :fingerprint, presence: true
    validates :host, presence: true
    validates :runbook_url, presence: true

    scope :recent_for_fingerprint, ->(fingerprint, since:) {
      where(fingerprint: fingerprint).where("created_at >= ?", since)
    }

    scope :open_for_host, ->(host) {
      joins(:job).merge(Job.open_threads).where(host: host)
    }
  end
end
