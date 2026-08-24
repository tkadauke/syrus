class MysqlConnection < ApplicationRecord
  attribute :credentials, :json
  attribute :agentic_access_enabled, :boolean, default: false
  encrypts :credentials

  after_initialize :seed_credentials

  validates :label, presence: true
  validates :host, presence: true
  validates :username, presence: true
  validates :port, presence: true, numericality: { only_integer: true, greater_than: 0, less_than: 65_536 }

  def password
    credentials.to_h["password"]
  end

  def password=(value)
    self.credentials = credentials.to_h.merge("password" => value)
  end

  private

  def seed_credentials
    self.credentials ||= {}
  end
end
