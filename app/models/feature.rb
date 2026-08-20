class Feature < ApplicationRecord
  ENABLED_CACHE_LOADED_KEY = "__all_features_loaded__".freeze
  PROCESS_CACHE_MUTEX = Mutex.new
  DEFAULT_PROCESS_CACHE_TTL = Rails.env.test? ? 0.seconds : 5.seconds

  class_attribute :process_cache_ttl, default: DEFAULT_PROCESS_CACHE_TTL

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
    load_enabled_cache!(cache) unless cache[ENABLED_CACHE_LOADED_KEY]
    return cache[key] if cache.key?(key)

    cache[key] = false
  end

  def self.load_enabled_cache!(cache)
    process_enabled_cache.each do |feature_slug, enabled|
      cache[feature_slug.to_s] = enabled == true
    end
    cache[ENABLED_CACHE_LOADED_KEY] = true
  end
  private_class_method :load_enabled_cache!

  def self.process_enabled_cache
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    PROCESS_CACHE_MUTEX.synchronize do
      if defined?(@process_enabled_cache) &&
          @process_enabled_cache &&
          @process_enabled_cache_expires_at.to_f > now
        return @process_enabled_cache
      end

      @process_enabled_cache = pluck(:slug, :enabled)
      @process_enabled_cache_expires_at = now + process_cache_ttl.to_f
      @process_enabled_cache
    end
  end
  private_class_method :process_enabled_cache

  def self.clear_enabled_cache!(slug = nil)
    cache = Current.feature_enabled_cache
    if cache
      if slug
        cache.delete(slug.to_s)
        cache.delete(ENABLED_CACHE_LOADED_KEY)
      else
        cache.clear
      end
    end

    PROCESS_CACHE_MUTEX.synchronize do
      @process_enabled_cache = nil
      @process_enabled_cache_expires_at = nil
    end
  end

  def self.terminal_enabled?
    enabled?(:terminal)
  end

  def self.video_walkthroughs_enabled?
    enabled?(:video_walkthroughs)
  end

  def self.chat_speech_to_text_enabled?
    enabled?(:chat_speech_to_text)
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

  def self.operational_log_indexing_enabled?
    enabled?(:operational_log_indexing)
  end

  def self.browser_error_auto_reports_enabled?
    enabled?(:browser_error_auto_reports)
  end

  def self.admin_supervisor_chat_enabled?
    enabled?(:admin_supervisor_chat)
  end

  def self.chat_context_compaction_enabled?
    enabled?(:chat_context_compaction)
  end

  def self.landing_validation_prefetch_enabled?
    enabled?(:landing_validation_prefetch)
  end

  # Instance-wide default for the visual_review Labs feature (headless-browser
  # QA screenshots taken against the worker's own in-step preview). A
  # repository's .syrus.yml `visual_review.enabled` setting overrides this
  # default per repo.
  def self.visual_review_enabled?
    enabled?(:visual_review)
  end

  def self.epicless_job_bundling_enabled?
    enabled?(:epicless_job_bundling)
  end

  private

  def clear_request_enabled_cache
    self.class.clear_enabled_cache!(slug)
    Current.performance_logging_enabled = nil if slug == "performance_logging"
    Current.operational_log_indexing_enabled = nil if slug == "operational_log_indexing"
  end
end
