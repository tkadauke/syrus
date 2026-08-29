require Rails.root.join("app/services/operational_logging")

OperationalLogging.install_notification_subscribers!
