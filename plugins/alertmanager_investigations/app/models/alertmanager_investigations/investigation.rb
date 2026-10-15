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
      escaped_host = sanitize_sql_like(host)
      joins(:job)
        .merge(Job.open_threads)
        .where("host = :host OR host LIKE :with_port OR host LIKE :bracketed_with_port",
          host: host,
          with_port: "#{escaped_host}:%",
          bracketed_with_port: "[#{escaped_host}]:%")
    }

    scope :open_for_repository, ->(repository) {
      joins(:job).merge(Job.open_threads).where(repository: repository)
    }
  end
end
