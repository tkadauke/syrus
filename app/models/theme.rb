class Theme < ApplicationRecord
  # Mirrors the persisted base semantic color tokens declared in
  # app/assets/tailwind/application.css. `on-brand` is the 13th token: text
  # painted on top of `brand` (e.g. Button's primary variant) needs its own
  # color because Ocean/Forest's dark-mode `brand` is light enough that
  # hardcoded white text fails contrast (see CLAUDE.md Job history / the
  # theme CSS generator for the resolved values).
  TOKEN_KEYS = %w[
    brand brand-emphasis surface surface-raised border text-primary
    text-secondary success warning danger info neutral on-brand
  ].freeze

  DERIVED_COLOR_TOKENS = {
    "page" => "var(--color-surface-raised)",
    "surface-subtle" => "var(--color-surface-raised)",
    "surface-inset" => "color-mix(in srgb, var(--color-surface) 70%, var(--color-border))",
    "border-strong" => "color-mix(in srgb, var(--color-border) 70%, var(--color-text-primary))",
    "text" => "var(--color-text-primary)",
    "text-muted" => "var(--color-text-secondary)",
    "text-subtle" => "color-mix(in srgb, var(--color-text-secondary) 70%, var(--color-surface))",
    "link" => "var(--color-brand-emphasis)",
    "success-surface" => "color-mix(in srgb, var(--color-surface) 94%, var(--color-success))",
    "success-border" => "color-mix(in srgb, var(--color-surface) 70%, var(--color-success))",
    "success-text" => "var(--color-success)",
    "warning-surface" => "color-mix(in srgb, var(--color-surface) 94%, var(--color-warning))",
    "warning-border" => "color-mix(in srgb, var(--color-surface) 70%, var(--color-warning))",
    "warning-text" => "var(--color-warning)",
    "danger-surface" => "color-mix(in srgb, var(--color-surface) 94%, var(--color-danger))",
    "danger-border" => "color-mix(in srgb, var(--color-surface) 70%, var(--color-danger))",
    "danger-text" => "var(--color-danger)",
    "info-surface" => "color-mix(in srgb, var(--color-surface) 94%, var(--color-info))",
    "info-border" => "color-mix(in srgb, var(--color-surface) 70%, var(--color-info))",
    "info-text" => "var(--color-info)",
    "neutral-surface" => "color-mix(in srgb, var(--color-surface) 94%, var(--color-neutral))",
    "neutral-border" => "color-mix(in srgb, var(--color-surface) 70%, var(--color-neutral))",
    "neutral-text" => "var(--color-neutral)"
  }.freeze

  # Syntax-highlighting token keys for Shiki's `css-variables` theme mode
  # . Names mirror exactly what @shikijs/core's
  # createCssVariablesTheme() looks up under `--shiki-<name>` (verified
  # against its theme-css-variables.ts source and by inspecting real
  # codeToTokensBase() output) -- `foreground` for otherwise-unstyled
  # tokens/whitespace, the rest prefixed `token-` for actual syntax scopes
  # (keyword, string, etc). app/frontend/lib/highlighter.ts's
  # cssVariablesTheme must keep the default `--shiki-` prefix for these
  # names to resolve with no translation layer.
  #
  # Deliberately NOT part of #tokens_has_required_shape like TOKEN_KEYS:
  # a custom/agent-authored theme that skips these still renders reasonably
  # via the `--shiki-*` fallback values in application.css, which resolve
  # through that same custom theme's own TOKEN_KEYS values (see the
  # fallback block's var(--color-*) indirection).
  SYNTAX_TOKEN_KEYS = %w[
    foreground token-keyword token-string token-string-expression
    token-comment token-constant token-function token-parameter
    token-punctuation token-link token-inserted token-deleted token-changed
  ].freeze

  # Extended (non-color) token groups: shape/control radius, panel
  # shadow/elevation, page/section spacing, control heights + table row
  # height (density), and typography/font choices. Unlike TOKEN_KEYS these
  # are NOT split by light/dark -- they mirror the single :root definition
  # of --radius-*, --shadow-panel, --space-*, --control-height-*,
  # --table-row-height, --font-*, and --text-* in
  # app/assets/tailwind/application.css, none of which currently vary
  # between light and dark mode. Stored as sibling top-level keys on
  # `tokens` alongside "light"/"dark" (e.g. tokens["shape"]["radius-panel"]).
  EXTENDED_TOKEN_GROUPS = {
    "shape" => %w[radius-control radius-panel radius-pill border-width],
    "shadow" => %w[shadow-panel],
    "spacing" => %w[space-page-x space-page-y space-section space-section-compact],
    "density" => %w[control-height-sm control-height-md table-row-height],
    "typography" => %w[font-sans font-mono text-page-title text-section-title text-body text-caption]
  }.freeze

  # Default value for every EXTENDED_TOKEN_GROUPS key, copied from
  # application.css's :root block. A stored theme that omits a group
  # entirely (including every color-only theme that predates this token
  # expansion), or omits individual keys within a group, gets these
  # defaults merged in by #tokens_with_defaults -- so old themes keep
  # working without a data migration/backfill.
  DEFAULT_EXTENDED_TOKENS = {
    "shape" => {
      "radius-control" => "0.375rem",
      "radius-panel" => "0.5rem",
      "radius-pill" => "999px",
      "border-width" => "1px"
    },
    "shadow" => {
      "shadow-panel" => "0 1px 2px rgb(0 0 0 / 0.06)"
    },
    "spacing" => {
      "space-page-x" => "1.5rem",
      "space-page-y" => "1.5rem",
      "space-section" => "1rem",
      "space-section-compact" => "0.75rem"
    },
    "density" => {
      "control-height-sm" => "2rem",
      "control-height-md" => "2.5rem",
      "table-row-height" => "3rem"
    },
    "typography" => {
      "font-sans" => "Inter, ui-sans-serif, system-ui, sans-serif",
      "font-mono" => "ui-monospace, SFMono-Regular, Menlo, monospace",
      "text-page-title" => "2rem",
      "text-section-title" => "0.95rem",
      "text-body" => "0.875rem",
      "text-caption" => "0.75rem"
    }
  }.freeze

  MODES = %w[light dark].freeze
  TERRACOTTA_SLUG = "terracotta".freeze

  # Pairs checked by #contrast_issues: body text against both surface levels,
  # each status tone against its own tinted "status pill" background
  # (see ColorContrast.blend), and `on-brand` against `brand` -- the exact
  # pairing `on-brand` was introduced for (see Button's primary variant) --
  # so a custom/agent-drafted theme can't slip an illegible brand button
  # past install_theme/update_user_theme the same way built-in Ocean/Forest
  # dark mode had to be hand-tuned to avoid. TonePill's tint reads as
  # roughly a 5-8% wash of the tone color over the page background across
  # Tailwind's -50/-950 shades; 0.06 lands in the middle of that range with
  # margin against AA's 4.5:1 floor for every built-in theme.
  TEXT_TOKEN_KEYS = %w[text-primary text-secondary].freeze
  BACKGROUND_TOKEN_KEYS = %w[surface surface-raised].freeze
  STATUS_TONE_KEYS = %w[success warning danger info neutral].freeze
  BRAND_TOKEN_KEY = "brand".freeze
  ON_BRAND_TOKEN_KEY = "on-brand".freeze
  STATUS_TONE_BACKGROUND_TINT_ALPHA = 0.06
  MIN_CONTRAST_RATIO = ColorContrast::AA_NORMAL_TEXT_RATIO

  belongs_to :owner_user, class_name: "User", optional: true
  has_many :users, foreign_key: :color_theme_id, dependent: :nullify, inverse_of: :color_theme

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true, format: { with: /\A[a-z0-9-]+\z/, message: "must be lowercase letters, numbers, and hyphens only" }
  validates :owner_user_id, absence: { message: "must be blank for built-in themes" }, if: :built_in?
  validate :tokens_has_required_shape

  scope :selectable_by, ->(user) { where(built_in: true).or(where(owner_user_id: user)) }
  scope :owned_custom_by, ->(user) { where(owner_user: user, built_in: false) }

  def self.terracotta
    find_by(slug: TERRACOTTA_SLUG)
  end

  def public_payload
    { id: id, slug: slug, name: name, built_in: built_in, position: position, tokens: tokens_with_defaults }
  end

  # Merges each EXTENDED_TOKEN_GROUPS group's stored overrides onto
  # DEFAULT_EXTENDED_TOKENS, leaving "light"/"dark" untouched. Missing
  # groups, and missing keys within a present group, resolve to the shared
  # default -- so a pre-expansion, color-only stored theme (or a
  # partially-specified new one) still returns a complete token payload.
  def tokens_with_defaults
    return tokens unless tokens.is_a?(Hash)

    extended = EXTENDED_TOKEN_GROUPS.keys.index_with do |group|
      DEFAULT_EXTENDED_TOKENS.fetch(group).merge(stored_group_tokens(group))
    end

    tokens.merge(extended)
  end

  # WCAG AA (4.5:1) contrast check across text/tone pairings, per mode.
  # Returns [] when tokens don't have the expected shape yet (that's
  # #tokens_has_required_shape's job to flag) or when every pairing passes.
  def contrast_issues
    return [] unless tokens.is_a?(Hash)

    MODES.flat_map do |mode|
      mode_tokens = tokens[mode]
      next [] unless mode_tokens.is_a?(Hash)

      text_background_issues(mode, mode_tokens) + status_tone_issues(mode, mode_tokens) + brand_contrast_issues(mode, mode_tokens)
    end
  end

  # Non-blocking counterpart to #contrast_issues for callers that only ever
  # warn (preview_theme, the live Style Guide preview panel) instead of
  # rejecting -- unlike install_theme/update_user_theme, these callers must
  # never raise on a malformed/placeholder color value, since the whole
  # point is to keep working through invalid intermediate states. Does not
  # change what #contrast_issues itself considers a failing pair.
  def contrast_warning_messages
    contrast_issues.map { |issue| issue.fetch(:message) }
  rescue StandardError => e
    Rails.logger.warn("Theme##{id || 'new'} contrast_issues raised while computing preview warnings: #{e.class}: #{e.message}")
    []
  end

  private

  def brand_contrast_issues(mode, mode_tokens)
    on_brand_color = mode_tokens[ON_BRAND_TOKEN_KEY]
    brand_color = mode_tokens[BRAND_TOKEN_KEY]
    return [] unless on_brand_color && brand_color

    [ contrast_issue(mode: mode, foreground_key: ON_BRAND_TOKEN_KEY, foreground_color: on_brand_color, background_key: BRAND_TOKEN_KEY, background_color: brand_color) ].compact
  end

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

    EXTENDED_TOKEN_GROUPS.each_key { |group| validate_extended_token_group(group) }
  end

  # Extended groups are optional -- a group missing entirely resolves to
  # DEFAULT_EXTENDED_TOKENS via #tokens_with_defaults. But a *present*
  # group must only contain known keys with string values, so a typo'd key
  # or a wrong-typed value (e.g. a number instead of a CSS length string)
  # is rejected instead of silently stored.
  def validate_extended_token_group(group)
    return unless tokens.key?(group)

    group_tokens = tokens[group]
    unless group_tokens.is_a?(Hash)
      errors.add(:tokens, "#{group} must be a hash of token values")
      return
    end

    allowed_keys = EXTENDED_TOKEN_GROUPS.fetch(group)
    unknown = group_tokens.keys - allowed_keys
    errors.add(:tokens, "#{group} has unknown keys: #{unknown.join(', ')}") if unknown.any?

    invalid = group_tokens.select { |key, value| allowed_keys.include?(key) && !value.is_a?(String) }
    errors.add(:tokens, "#{group} values must be strings: #{invalid.keys.join(', ')}") if invalid.any?
  end

  def stored_group_tokens(group)
    value = tokens[group]
    value.is_a?(Hash) ? value : {}
  end
end
