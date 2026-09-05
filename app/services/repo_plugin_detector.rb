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

  def self.observed_for(repo_path)
    new(repo_path).observe
  end

  def detect
    detect_among(Syrus::PluginRegistry.all_plugins.select(&:enabled?))
  end

  # The same detection widened to every *installed* plugin, enabled or not.
  #
  # This is the signal a disabled plugin has no other way to produce: a Python
  # repo cannot tell you it wants the Python plugin using the Python plugin.
  # It costs nothing extra -- the detectors live in each plugin's `lib/`, which
  # the gem requires whatever the plugin's enabled state, and they are the same
  # file-existence checks the enabled pass already ran against this clone.
  def observe
    detect_among(Syrus::PluginRegistry.all_plugins)
  end

  private

  attr_reader :repo_path

  # A plugin whose detector raises must not take the detection pass with it:
  # every other plugin's answer is still good, and a missing one only means a
  # feature is not offered.
  def detect_among(manifests)
    manifests.filter_map do |manifest|
      manifest.name if detected_by?(manifest)
    rescue StandardError => e
      Rails.logger.debug { "[repo_plugin_detector] #{manifest.name}: #{e.class}: #{e.message}" }
      nil
    end.uniq
  end

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
