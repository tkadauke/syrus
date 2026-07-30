class PluginRecord < ApplicationRecord
  validates :name, presence: true, uniqueness: true

  # Enabling a previously disabled plugin requires a restart (the gem's engine
  # won't have registered itself if it was never loaded). Disabling takes effect
  # immediately for new requests — providers_for re-queries the DB — but the gem
  # itself remains in memory until restart.

  after_initialize do
    self.config ||= {}
  end
end
