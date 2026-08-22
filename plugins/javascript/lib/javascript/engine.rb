require "rails"

module JavaScript
  class Engine < ::Rails::Engine
    config.after_initialize do
      # Wire up the interface modules now that Zeitwerk is active and all
      # Syrus::Plugin::* constants are autoloadable from the main app's lib/.
      JavaScript::PrepareDetector.include(Syrus::Plugin::PrepareDetector)
      JavaScript::PreviewProvider.include(Syrus::Plugin::PreviewProvider)
      JavaScript::EslintGraderAugmentor.include(Syrus::Plugin::GraderAugmentor)
      JavaScript::ReviewCriteriaProvider.include(Syrus::Plugin::ReviewCriteriaProvider)
      JavaScript::EslintAutofix.include(Syrus::Plugin::AutofixCommand)
      JavaScript::PrettierAutofix.include(Syrus::Plugin::AutofixCommand)
      JavaScript::DependencyAuditCommand.include(Syrus::Plugin::DependencyAuditCommand)

      Syrus::PluginRegistry.register(
        name:             "javascript",
        version:          JavaScript::VERSION,
        description:      "Node/JS (and TS) prepare detection and dev-server preview: yarn/pnpm/npm lockfile priority, package.json scripts.dev/start; ESLint grader detail; ESLint/Prettier autofix; npm/yarn/pnpm audit dependency scanning; default `any`-type review criterion",
        homepage:         "https://github.com/tkadauke/syrus",
        icon_url:         "/plugin-icons/javascript.svg",
        prepare_priority: 20,
        provides: {
          prepare_detector:         JavaScript::PrepareDetector,
          preview_provider:         JavaScript::PreviewProvider,
          grader_augmentor:         JavaScript::EslintGraderAugmentor,
          review_criteria_provider: JavaScript::ReviewCriteriaProvider,
          autofix_command:          [ JavaScript::EslintAutofix, JavaScript::PrettierAutofix ],
          dependency_audit_command: JavaScript::DependencyAuditCommand
        }
      )
    end
  end
end
