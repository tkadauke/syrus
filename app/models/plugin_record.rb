class PluginRecord < ApplicationRecord
  SEARCH_COLUMNS = %w[name display_name description category].freeze

  validates :name, presence: true, uniqueness: true
  validate :enabled_plugin_is_disableable

  # Simple full text search over the manifest fields we mirror onto plain
  # columns (see Syrus::PluginRegistry.upsert_plugin_record!). MySQL gets a
  # real FULLTEXT MATCH ... AGAINST query (index added in
  # db/migrate/20260814142224_add_search_fields_to_plugin_records.rb);
  # sqlite (dev/test) falls back to a LIKE scan since it has no FULLTEXT
  # index type.
  def self.search(query)
    query = query.to_s.strip
    return all if query.blank?

    if connection.adapter_name.downcase.include?("mysql")
      where("MATCH(#{SEARCH_COLUMNS.join(', ')}) AGAINST (?)", query)
    else
      like = "%#{sanitize_sql_like(query)}%"
      where(SEARCH_COLUMNS.map { |column| "#{column} LIKE ? ESCAPE '\\'" }.join(" OR "), *[ like ] * SEARCH_COLUMNS.size)
    end
  end

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
