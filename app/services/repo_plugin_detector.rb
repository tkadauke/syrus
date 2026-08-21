# Centralized per-repo plugin/language detection. Computed once per Run
# (see Steps::Prepare) against the freshly-cloned workspace, then cached on
# the Workflow as the "detected_plugins" artifact so every later Step and
# extension point without its own natural per-repo gate (:prompt_injector,
# :review_criteria_provider, etc.) can check membership instead of
# re-deriving file-existence checks itself.
#
# Reuses the two extension points that already answer "does this plugin
# apply to this repo" instead of inventing a third detection mechanism:
#
#   - :prepare_detector — language plugins (ruby, javascript, python, go).
#     detect?(repo_path) is a CLASS method (Syrus::Plugin::PrepareDetector).
#   - :preview_provider  — framework plugins (rails, django) that don't
#     register their own :prepare_detector. detect?(repo_path) is an
#     INSTANCE method (Syrus::Plugin::PreviewProvider).
#
# Only enabled plugins are considered (Syrus::PluginRegistry.all_plugins
# reflects current PluginRecord state), and the result is the union of
# matching plugin manifest names, de-duplicated.
class RepoPluginDetector
  EXTENSION_POINTS = %i[prepare_detector preview_provider].freeze

  def self.for(repo_path)
    new(repo_path).detect
  end

  def initialize(repo_path)
    @repo_path = repo_path.to_s
  end

  def detect
    Syrus::PluginRegistry.all_plugins.select(&:enabled?).filter_map do |manifest|
      manifest.name if detected_by?(manifest)
    end.uniq
  end

  private

  attr_reader :repo_path

  def detected_by?(manifest)
    EXTENSION_POINTS.any? do |extension_point|
      Array(manifest.provides[extension_point]).any? { |provider| provider_detects?(provider) }
    end
  end

  # Providers can be registered as either a class/instance that already
  # responds to `detect?` (prepare_detector's class-method form, or a
  # directly-registered preview_provider instance) or a class that needs
  # instantiating first (preview_provider's instance-method form) —
  # mirrors Syrus::Plugin::PreviewProvider.instantiate.
  def provider_detects?(provider)
    instance = provider.respond_to?(:detect?) ? provider : provider.try(:new)
    instance.respond_to?(:detect?) && instance.detect?(repo_path)
  end
end
