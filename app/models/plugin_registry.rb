require "digest"
require "uri"

class PluginRegistry < ApplicationRecord
  CANONICAL_URL = "https://github.com/tkadauke/syrus-plugins".freeze
  MAX_CONFIGURED = 10
  NAME_PATTERN = /\A[a-z][a-z0-9_-]*\z/

  belongs_to :created_by, class_name: "User", optional: true
  has_many :plugin_releases, dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: true, format: { with: NAME_PATTERN }
  validates :url, presence: true, uniqueness: true
  validate :supported_safe_url
  validate :configured_registry_limit

  scope :active, -> { where(removed_at: nil) }
  scope :enabled, -> { active.where(enabled: true) }

  def canonical? = url == CANONICAL_URL
  def read_only? = environment_managed?
  def cache_key = "registry-#{id}"
  def configuration_error = nil

  def self.ensure_canonical!
    find_or_create_by!(url: CANONICAL_URL) { |registry| registry.name = "canonical"; registry.enabled = true }
  end

  def self.sources
    ensure_canonical!
    configured = active.where(environment_managed: false).order(:id).to_a
    env_url = ENV["SYRUS_PLUGIN_REGISTRY_URL"].to_s.strip
    return configured if env_url.blank? || configured.any? { |source| source.url == env_url }

    environment = begin
      ensure_environment!(env_url)
    rescue ActiveRecord::RecordInvalid, URI::InvalidURIError => error
      InvalidEnvironmentSource.new(env_url, error.message)
    end
    configured + [ environment ]
  end

  def self.ensure_environment!(url)
    registry = find_or_initialize_by(url:)
    if registry.new_record? || registry.removed_at?
      registry.assign_attributes(name: environment_name(url), enabled: true, environment_managed: true, removed_at: nil)
    end
    registry.save! if registry.changed?
    registry
  end

  def self.environment_name(url)
    host = URI.parse(url.delete_prefix("git+")).host.to_s.parameterize
    "environment-#{host}-#{Digest::SHA256.hexdigest(url)[0, 8]}"
  end

  class TransientSource
    attr_reader :url

    def initialize(url) = @url = url.to_s
    def id = nil
    def name = "transient-#{Digest::SHA256.hexdigest(url)[0, 8]}"
    def enabled? = true
    def canonical? = url == CANONICAL_URL
    def read_only? = true
    def cache_key = "transient-#{Digest::SHA256.hexdigest(url)[0, 16]}"
    def configuration_error = nil
  end

  class InvalidEnvironmentSource < TransientSource
    def initialize(url, error)
      super(url)
      @error = error
    end

    def name = "environment-invalid-#{Digest::SHA256.hexdigest(url)[0, 8]}"
    def configuration_error = @error
  end

  private

  def configured_registry_limit
    return if canonical? || environment_managed?
    reactivating = new_record? || (will_save_change_to_removed_at? && removed_at.nil?)
    return unless reactivating

    configured = self.class.active.where(environment_managed: false).where.not(url: CANONICAL_URL).where.not(id:)
    errors.add(:base, "at most #{MAX_CONFIGURED} plugin registries may be configured") if configured.count >= MAX_CONFIGURED
  end

  def supported_safe_url
    uri = URI.parse(url.to_s.delete_prefix("git+"))
    errors.add(:url, "must use HTTPS or git+https") unless uri.is_a?(URI::HTTPS)
    errors.add(:url, "must not contain credentials") if uri.userinfo.present?
    errors.add(:url, "host is not permitted") if uri.host.blank? || !SsrfGuard.safe_host?(uri.host)
  rescue URI::InvalidURIError
    errors.add(:url, "is invalid")
  end
end
