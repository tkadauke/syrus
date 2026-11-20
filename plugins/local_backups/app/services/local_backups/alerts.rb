module LocalBackups
  module Alerts
    include Syrus::Host::SystemAlertProvider

    def self.system_alerts
      [ recent_failure, invalid_backups ].compact
    end

    def self.recent_failure
      failed = Backup.where(state: "failed", failed_at: 24.hours.ago..).order(failed_at: :desc).first
      return unless failed

      Syrus::Host::SystemAlert.build(
        id: "local_backups:failed",
        dismissal_key: "local_backups:failed:#{failed.id}:#{failed.failed_at.to_i}",
        severity: :alarm,
        title: "Local backup creation failed.",
        message: "The latest local recovery-bundle attempt failed. Its error details are redacted from this alert.",
        action_steps: [ "Open Admin → Local Backups, verify storage capacity and permissions, then create a new backup." ],
        cta: { text: "Open Local Backups", path: "/admin/local_backups" }
      )
    end

    def self.invalid_backups
      count = Backup.where(state: "completed", verification_state: "invalid").count
      return unless count.positive?

      Syrus::Host::SystemAlert.build(
        id: "local_backups:invalid",
        dismissal_key: "local_backups:invalid:#{count}",
        severity: :warn,
        title: "A local backup failed validation.",
        message: "#{count} retained local recovery bundle#{'s' unless count == 1} failed validation.",
        action_steps: [ "Open Admin → Local Backups and create a new validated recovery point before deleting invalid bundles." ],
        cta: { text: "Open Local Backups", path: "/admin/local_backups" }
      )
    end
  end
end
