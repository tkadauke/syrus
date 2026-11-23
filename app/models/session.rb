class Session < ApplicationRecord
  belongs_to :user
  has_many :push_devices, dependent: :destroy
end
