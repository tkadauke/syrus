module Syrus
  module Plugin
    # Contract for one namespaced `.syrus.yml` contribution. Providers own
    # their schema; the host only stores the parsed value and its safe form.
    module RepositoryConfiguration
      def self.included(base) = base.extend(DefaultMethods)

      module DefaultMethods
        def legacy_keys = []
        def overlay(root:, project:) = project.nil? ? root : project
        def affected_project?(configuration:, project:, changed_files:) = true
      end
    end
  end
end
