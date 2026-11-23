class Session < ApplicationRecord
  belongs_to :user
  # Signing out must stop pushes to the device that registered under this session.
  has_many :push_devices, dependent: :destroy
end
