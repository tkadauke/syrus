class Session < ApplicationRecord
  belongs_to :user
  # Signing out must stop pushes to the device that was using this session.
  has_many :mobile_devices, dependent: :destroy
end
