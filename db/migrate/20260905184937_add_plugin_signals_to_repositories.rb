# The plugin names a repository's file layout matched, the last time Syrus had
# a clone of it in hand.
#
# Deliberately separate from the Workflow's "detected_plugins" artifact, which
# stays the authority for a Run: that one is computed fresh against the actual
# checkout and covers enabled plugins only. This is the lagging, instance-wide
# copy, and it covers plugins that are installed but off -- the ones that have
# no other way to notice they are needed.
#
# Nullable with no default: "never observed" and "observed nothing" are
# different answers, and a recommendation must not fire on the first.
class AddPluginSignalsToRepositories < ActiveRecord::Migration[8.1]
  def up
    add_column :repositories, :plugin_signals, :json unless column_exists?(:repositories, :plugin_signals)

    return if column_exists?(:repositories, :plugin_signals_observed_at)

    add_column :repositories, :plugin_signals_observed_at, :datetime
  end

  def down
    remove_column :repositories, :plugin_signals if column_exists?(:repositories, :plugin_signals)

    return unless column_exists?(:repositories, :plugin_signals_observed_at)

    remove_column :repositories, :plugin_signals_observed_at
  end
end
