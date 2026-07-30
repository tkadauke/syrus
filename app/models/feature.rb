class Feature < ApplicationRecord
  after_commit :clear_request_enabled_cache

  normalizes :slug, with: ->(slug) { slug.to_s.strip }
  normalizes :category, with: ->(category) { category.to_s.strip }
  normalizes :name, with: ->(name) { name.to_s.strip }

  validates :slug, presence: true, uniqueness: true
  validates :category, presence: true
  validates :name, presence: true

  attr_accessor :name_i18n_key, :description_i18n_key

  def self.enabled?(slug)
    key = slug.to_s
    cache = Current.feature_enabled_cache ||= {}
    return cache[key] if cache.key?(key)

    cache[key] = find_by(slug: key)&.enabled? || false
  end

  def self.clear_enabled_cache!(slug = nil)
    cache = Current.feature_enabled_cache
    return unless cache

    slug ? cache.delete(slug.to_s) : cache.clear
  end

  def self.terminal_enabled?
    enabled?(:terminal)
  end

  def self.video_walkthroughs_enabled?
    enabled?(:video_walkthroughs)
  end

  def self.coding_mode_enabled?
    return false if AppSetting.simple?

    enabled?(:coding_mode)
  end

  def self.local_mode_enabled?
    return false if AppSetting.simple?

    enabled?(:local_mode)
  end

  def self.agent_insights_enabled?
    enabled?(:agent_insights)
  end

  def self.unified_work_engine_reconciler_enabled?
    enabled?(WorkEngine::Gate::FEATURE_SLUG)
  end

  private

  def clear_request_enabled_cache
    self.class.clear_enabled_cache!(slug)
    Current.performance_logging_enabled = nil if slug == "performance_logging"
  end
end
