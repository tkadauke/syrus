module Syrus
  module Host
    # Finds or creates the persisted settings record of one plugin by name.
    # The record's columns beyond those the plugin declares are not promised.
    module PluginRecords
      def self.find_by_name(name) = ::PluginRecord.find_by(name: name)

      def self.ensure!(name) = ::PluginRecord.find_or_create_by!(name: name)
    end
  end
end
