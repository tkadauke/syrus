class PluginRecord < ApplicationRecord
  validates :name, presence: true, uniqueness: true
  validate :enabled_plugin_is_disableable

  # Installation means the gem's engine registered during this boot. Enabling and
  # disabling installed plugins takes effect for new requests because registry
  # lookups consult this row every time.

  after_initialize do
    self.config ||= {}
    self.default_enabled = true if has_attribute?(:default_enabled) && default_enabled.nil?
    self.disableable = true if has_attribute?(:disableable) && disableable.nil?
  end

  after_commit on: :update do
    next unless saved_change_to_enabled?

    manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == name }
    next unless manifest
    next if Array(manifest.provides[:callbacks]).empty?

    event = enabled? ? "on_enable" : "on_disable"
    queue = manifest.home_queue == :default ? PluginLifecycleJob.queue_name : manifest.home_queue.to_s
    PluginLifecycleJob.set(queue: queue).perform_later(name, event)
  end

  def effective_enabled?
    enabled? || !disableable?
  end

  private

  def enabled_plugin_is_disableable
    return unless has_attribute?(:disableable)
    return if enabled?
    return if disableable?

    errors.add(:enabled, "cannot be false for a non-disableable plugin")
  end
end
