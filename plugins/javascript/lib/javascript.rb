require "javascript/prepare_detector"
require "javascript/preview_provider"
require "javascript/eslint_grader_augmentor"
require "javascript/eslint_autofix"
require "javascript/prettier_autofix"
require "javascript/dependency_audit_command"
require "javascript/review_criteria_provider"

module JavaScript
  extend Syrus::PluginApi

  syrus_plugin "javascript" do
    description "Node/JS (and TS) prepare detection and dev-server preview: yarn/pnpm/npm lockfile priority, package.json scripts.dev/start; ESLint grader detail; ESLint/Prettier autofix; npm/yarn/pnpm audit dependency scanning; default `any`-type review criterion"
    long_description "JavaScript adds Node, JavaScript, and TypeScript project intelligence. It detects package managers from lockfiles, prepares dependencies, hosts dev-server previews from common package scripts, augments ESLint grader output, and supplies autofix/dependency-audit commands.\n\nUse it for frontend apps, Node services, static sites, and mixed repositories with JS or TS components. Framework-specific behavior can layer on top of this plugin later."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/javascript.svg"
    author "Thomas Kadauke"
    category "language"
    prepare_priority 20
    provides prepare_detector: "JavaScript::PrepareDetector",
             preview_provider: "JavaScript::PreviewProvider",
             grader_augmentor: "JavaScript::EslintGraderAugmentor",
             review_criteria_provider: "JavaScript::ReviewCriteriaProvider",
             autofix_command: [ "JavaScript::EslintAutofix", "JavaScript::PrettierAutofix" ],
             dependency_audit_command: "JavaScript::DependencyAuditCommand"
  end
end
