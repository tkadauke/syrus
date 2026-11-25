# Ownership boundary for runtime images. The owner is an opaque
# (owner_kind, owner_ref) pair so core carries no consumer vocabulary; plugins
# choose their own kinds. Namespaces never share images.
class RuntimeImageNamespace < ApplicationRecord
  NAME_FORMAT = /\A[a-z0-9]+(?:[._\/-][a-z0-9]+)*\z/

  has_many :runtime_images, dependent: :restrict_with_error

  validates :name, presence: true, length: { maximum: 191 }, format: { with: NAME_FORMAT }, uniqueness: true
  validates :owner_kind, :owner_ref, :provider_key, presence: true
  validates :retention_days, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
end
