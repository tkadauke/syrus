class Handle < ApplicationRecord
  FORMAT = /\A[a-z0-9_-]{3,32}\z/

  belongs_to :owner, polymorphic: true, optional: true
  normalizes :handle, with: ->(value) { value.to_s.downcase.strip }

  validates :handle,
            presence: true,
            format: { with: FORMAT, message: "must be 3 to 32 lowercase letters, numbers, underscores, or hyphens" },
            uniqueness: { case_sensitive: false }
  validates :owner_id, uniqueness: { scope: :owner_type }, allow_nil: true

  def reserved? = owner_type.nil? && owner_id.nil?
end
