class SystemAlertNotification < ApplicationRecord
  validates :dismissal_key, presence: true, uniqueness: true
  validates :alert_id, :severity, :title, presence: true
end
