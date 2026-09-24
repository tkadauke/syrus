class PluginRecord < ApplicationRecord
  # Stamped here rather than in the enable action so every path that turns a
  # plugin on -- admin UI, cascade of a dependency, console, seeds -- records
  # it. Never cleared: "has been enabled here" is a fact about the instance's
  # history, and the rows a plugin left behind do not disappear when it is
  # switched off again.
  before_save :remember_enablement

  SEARCH_COLUMNS = %w[name display_name description category].freeze

  validates :name, presence: true, uniqueness: true
  validate :enabled_plugin_is_disableable

  # Simple full text search over the manifest fields we mirror onto plain
  # columns (see Syrus::PluginRegistry.upsert_plugin_record!). MySQL gets a
  # real FULLTEXT MATCH ... AGAINST query (index added in
  # db/migrate/20260814142224_add_search_fields_to_plugin_records.rb);
  # sqlite (dev/test) falls back to a LIKE scan since it has no FULLTEXT
  # index type.
  #
  # BOOLEAN MODE with a trailing wildcard per word, rather than the default
  # natural-language mode, because plugin `name`s are underscore_separated
  # (a word character to MySQL's built-in parser, so "video_walkthroughs" is
  # ONE indexed token) and `display_name`s use plain-English surface forms
  # ("Walkthrough Videos"). Natural-language mode only matches whole tokens,
  # so searching "video" matched neither the "video_walkthroughs" token nor
  # the plural "videos" token. A trailing "*" makes each word a prefix match
  # instead, so "video*" matches both.
  def self.search(query)
    query = query.to_s.strip
    return all if query.blank?

    if connection.adapter_name.downcase.include?("mysql")
      boolean_query = boolean_prefix_query(query)
      return none if boolean_query.blank?

      where("MATCH(#{SEARCH_COLUMNS.join(', ')}) AGAINST (? IN BOOLEAN MODE)", boolean_query)
    else
      like = "%#{sanitize_sql_like(query)}%"
      where(SEARCH_COLUMNS.map { |column| "#{column} LIKE ? ESCAPE #{like_escape_sql}" }.join(" OR "), *[ like ] * SEARCH_COLUMNS.size)
    end
  end

  def self.boolean_prefix_query(query)
    query.scan(/[[:alnum:]_]+/).map { |word| "+#{word}*" }.join(" ")
  end
  private_class_method :boolean_prefix_query

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

  after_commit { Syrus::PluginRegistry.clear_plugin_record_cache! if defined?(Syrus::PluginRegistry) }

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

  def remember_enablement
    # Guarded like enabled_plugin_is_disableable above: this runs on databases
    # that have not taken the migration yet (a worker on the old image during a
    # rollout, a console against an older schema).
    return unless has_attribute?(:ever_enabled)

    self.ever_enabled = true if enabled?
  end
end
