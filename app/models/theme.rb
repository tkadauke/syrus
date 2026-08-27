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

  # Pairs checked by #contrast_issues: body text against both surface levels,
  # plus each status tone against its own tinted "status pill" background
  # (see ColorContrast.blend). TonePill's tint reads as roughly a 5-8% wash
  # of the tone color over the page background across Tailwind's -50/-950
  # shades; 0.06 lands in the middle of that range with margin against AA's
  # 4.5:1 floor for every built-in theme.
  TEXT_TOKEN_KEYS = %w[text-primary text-secondary].freeze
  BACKGROUND_TOKEN_KEYS = %w[surface surface-raised].freeze
  STATUS_TONE_KEYS = %w[success warning danger info neutral].freeze
  STATUS_TONE_BACKGROUND_TINT_ALPHA = 0.06
  MIN_CONTRAST_RATIO = ColorContrast::AA_NORMAL_TEXT_RATIO

  belongs_to :owner_user, class_name: "User", optional: true
  has_many :users, foreign_key: :color_theme_id, dependent: :nullify, inverse_of: :color_theme

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true, format: { with: /\A[a-z0-9-]+\z/, message: "must be lowercase letters, numbers, and hyphens only" }
  validates :owner_user_id, absence: { message: "must be blank for built-in themes" }, if: :built_in?
  validate :tokens_has_required_shape

  scope :selectable_by, ->(user) { where(built_in: true).or(where(owner_user_id: user)) }

  def self.terracotta
    find_by(slug: TERRACOTTA_SLUG)
  end

  def public_payload
    { id: id, slug: slug, name: name, built_in: built_in, tokens: tokens }
  end

  # WCAG AA (4.5:1) contrast check across text/tone pairings, per mode.
  # Returns [] when tokens don't have the expected shape yet (that's
  # #tokens_has_required_shape's job to flag) or when every pairing passes.
  def contrast_issues
    return [] unless tokens.is_a?(Hash)

    MODES.flat_map do |mode|
      mode_tokens = tokens[mode]
      next [] unless mode_tokens.is_a?(Hash)

      text_background_issues(mode, mode_tokens) + status_tone_issues(mode, mode_tokens)
    end
  end

  private

  def text_background_issues(mode, mode_tokens)
    TEXT_TOKEN_KEYS.product(BACKGROUND_TOKEN_KEYS).filter_map do |text_key, background_key|
      text_color = mode_tokens[text_key]
      background_color = mode_tokens[background_key]
      next unless text_color && background_color

      contrast_issue(mode: mode, foreground_key: text_key, foreground_color: text_color, background_key: background_key, background_color: background_color)
    end
  end

  def status_tone_issues(mode, mode_tokens)
    surface = mode_tokens["surface"]
    return [] unless surface

    STATUS_TONE_KEYS.filter_map do |tone_key|
      tone_color = mode_tokens[tone_key]
      next unless tone_color

      tinted_background = ColorContrast.blend(surface, tone_color, STATUS_TONE_BACKGROUND_TINT_ALPHA)
      contrast_issue(mode: mode, foreground_key: tone_key, foreground_color: tone_color, background_key: "#{tone_key} background", background_color: tinted_background)
    end
  end

  def contrast_issue(mode:, foreground_key:, foreground_color:, background_key:, background_color:)
    ratio = ColorContrast.ratio(foreground_color, background_color)
    return nil if ratio >= MIN_CONTRAST_RATIO

    {
      mode: mode,
      foreground: foreground_key,
      foreground_color: foreground_color,
      background: background_key,
      background_color: background_color,
      ratio: ratio.round(2),
      required_ratio: MIN_CONTRAST_RATIO,
      message: "#{mode} #{foreground_key} (#{foreground_color}) on #{background_key} (#{background_color}) has contrast #{ratio.round(2)}:1, needs at least #{MIN_CONTRAST_RATIO}:1 for WCAG AA"
    }
  end

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
