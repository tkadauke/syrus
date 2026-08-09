class Passkey < ApplicationRecord
  belongs_to :user

  validates :external_id, presence: true
  validates :public_key, presence: true

  def self.find_by_external_id(id)
    find_by(external_id: id)
  end
end
