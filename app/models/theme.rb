class Theme < ApplicationRecord
  # Mirrors the semantic color tokens declared in
  # app/assets/tailwind/application.css. `on-brand` is the 13th token: text
  # painted on top of `brand` (e.g. Button's primary variant) needs its own
  # color because Ocean/Forest's dark-mode `brand` is light enough that
  # hardcoded white text fails contrast (see CLAUDE.md Job history / the
  # theme CSS generator for the resolved values).
  TOKEN_KEYS = %w[
    brand brand-emphasis surface surface-raised border text-primary
    text-secondary success warning danger info neutral on-brand
  ].freeze
  MODES = %w[light dark].freeze
  TERRACOTTA_SLUG = "terracotta".freeze

  belongs_to :owner_user, class_name: "User", optional: true
  has_many :users, foreign_key: :color_theme_id, dependent: :nullify, inverse_of: :color_theme

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true, format: { with: /\A[a-z0-9-]+\z/, message: "must be lowercase letters, numbers, and hyphens only" }
  validates :owner_user_id, absence: { message: "must be blank for built-in themes" }, if: :built_in?
  validate :tokens_has_required_shape

  def self.terracotta
    find_by(slug: TERRACOTTA_SLUG)
  end

  private

  def tokens_has_required_shape
    unless tokens.is_a?(Hash)
      errors.add(:tokens, "must be a hash with light/dark keys")
      return
    end

    MODES.each do |mode|
      mode_tokens = tokens[mode]
      unless mode_tokens.is_a?(Hash)
        errors.add(:tokens, "must include a #{mode} hash")
        next
      end

      missing = TOKEN_KEYS - mode_tokens.keys
      errors.add(:tokens, "#{mode} is missing keys: #{missing.join(', ')}") if missing.any?
    end
  end
end
