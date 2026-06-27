class Feature < ApplicationRecord
  normalizes :slug, with: ->(slug) { slug.to_s.strip }
  normalizes :category, with: ->(category) { category.to_s.strip }
  normalizes :name, with: ->(name) { name.to_s.strip }

  validates :slug, presence: true, uniqueness: true
  validates :category, presence: true
  validates :name, presence: true

  def self.enabled?(slug)
    find_by(slug: slug.to_s)&.enabled? || false
  end

  def self.terminal_enabled?
    enabled?(:terminal)
  end
end
