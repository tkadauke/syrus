class Tag < ApplicationRecord
  PALETTE = {
    "gray" => { bg: "#f3f4f6", text: "#374151" },
    "red" => { bg: "#fee2e2", text: "#991b1b" },
    "amber" => { bg: "#fef3c7", text: "#92400e" },
    "green" => { bg: "#dcfce7", text: "#166534" },
    "blue" => { bg: "#dbeafe", text: "#1d4ed8" },
    "indigo" => { bg: "#e0e7ff", text: "#3730a3" },
    "violet" => { bg: "#ede9fe", text: "#6d28d9" },
    "pink" => { bg: "#fce7f3", text: "#be185d" }
  }.freeze

  belongs_to :user
  has_many :job_tags, dependent: :destroy
  has_many :jobs, through: :job_tags

  normalizes :name, with: ->(name) { name.to_s.strip }
  normalizes :color, with: ->(color) { color.to_s.strip.presence || "gray" }

  validates :name, presence: true, length: { maximum: 80 },
                   uniqueness: { scope: :user_id }
  validates :color, presence: true
  validate :color_is_palette_key_or_hex

  scope :ordered, -> { order(Arel.sql("LOWER(name) ASC")) }

  def self.palette_keys
    PALETTE.keys
  end

  private

  def color_is_palette_key_or_hex
    return if PALETTE.key?(color)
    return if color.match?(/\A#[0-9a-fA-F]{6}\z/)

    errors.add(:color, "must be a palette key or hex color")
  end
end
