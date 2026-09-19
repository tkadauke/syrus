class BootstrapLock < ApplicationRecord
  validates :name, presence: true

  def self.fetch!(name)
    create_or_find_by!(name: name)
  end
end
