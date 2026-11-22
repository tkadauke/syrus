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
  validate :configured_registry_limit, on: :create

  scope :enabled, -> { where(enabled: true) }

  def canonical? = url == CANONICAL_URL
  def read_only? = false
  def cache_key = "registry-#{id}"

  def self.ensure_canonical!
    find_or_create_by!(url: CANONICAL_URL) { |registry| registry.name = "canonical"; registry.enabled = true }
  end

  def self.sources
    ensure_canonical!
    configured = order(:id).to_a
    env_url = ENV["SYRUS_PLUGIN_REGISTRY_URL"].to_s.strip
    return configured if env_url.blank? || configured.any? { |source| source.url == env_url }
    configured + [ EnvironmentSource.new(env_url) ]
  end

  class EnvironmentSource
    attr_reader :url
    def initialize(url) = @url = url
    def id = nil
    def name = "environment-#{URI.parse(url).host.to_s.parameterize}"
    def enabled? = true
    def canonical? = url == CANONICAL_URL
    def read_only? = true
    def cache_key = "environment-#{Digest::SHA256.hexdigest(url)[0, 16]}"
  end

  private

  def configured_registry_limit
    errors.add(:base, "at most #{MAX_CONFIGURED} plugin registries may be configured") if self.class.count >= MAX_CONFIGURED
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
