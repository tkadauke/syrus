# Centralized per-repo plugin/language detection. Computed once per Run
# (see Steps::Prepare) against the freshly-cloned workspace, then cached on
# the Workflow as the "detected_plugins" artifact so every later Step and
# capability without its own natural per-repo gate can check membership instead of
# re-deriving file-existence checks itself.
#
# Reuses declarations that explicitly answer "does this plugin apply to this
# repo", including family declarations marked as language support:
#
#   - Ecosystem's language-support capability — language plugins.
#   - :preview_provider  — framework plugins (rails, django) that don't
#     register their own Ecosystem detector. detect?(repo_path) is an
#     INSTANCE method (Syrus::Plugin::PreviewProvider).
#
# Only enabled plugins are considered (Syrus::PluginRegistry.all_plugins
# reflects current PluginRecord state), and the result is the union of
# matching plugin manifest names, de-duplicated.
class RepoPluginDetector
  EXTENSION_POINTS = %i[preview_provider].freeze

  def self.for(repo_path, repository: nil)
    new(repo_path, repository:).detect
  end

  def initialize(repo_path, repository: nil)
    @repo_path = repo_path.to_s
    @repository = repository
  end

  def self.observed_for(repo_path, repository: nil)
    new(repo_path, repository:).observe
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

  attr_reader :repo_path, :repository

  # A plugin whose detector raises must not take the detection pass with it:
  # every other plugin's answer is still good, and a missing one only means a
  # feature is not offered.
  def detect_among(manifests)
    manifests.filter_map do |manifest|
      manifest.name if detected_by?(manifest)
    # ScriptError too: a family provider is resolved by name only here, so a
    # provider file that fails to load surfaces as LoadError / SyntaxError
    # (the same pair Syrus::Plugin::Conformance contains).
    rescue StandardError, ScriptError => e
      Rails.logger.debug { "[repo_plugin_detector] #{manifest.name}: #{e.class}: #{e.message}" }
      nil
    end.uniq
  end

  def detected_by?(manifest)
    extension_point_match = EXTENSION_POINTS.any? do |extension_point|
      Array(manifest.provides[extension_point]).any? { |provider| provider_detects?(provider) }
    end
    extension_point_match || family_language_support?(manifest)
  end

  # Only a conforming declaration is called, the same gate Dispatch, the
  # legacy bridge, and PluginRegistry.capability_providers apply. Checked per
  # manifest because #observe deliberately includes disabled plugins, which
  # the registry's capability lookup leaves out.
  def family_language_support?(manifest)
    families = Syrus::Plugin::Family.all.select(&:indicates_language_support?)
    return false if families.empty? || manifest.family_provides.empty?

    conformance = Syrus::Plugin::Conformance.new([ manifest ])
    families.any? do |family|
      next false unless conformance.conforming?(plugin: manifest.name, family: family.name)

      manifest.family_provides.any? do |declaration|
        capability = family.language_support_capability
        next false unless declaration.family == family.name && declaration.capabilities.include?(capability)

        reference = Syrus::Plugin::CapabilityProvider.new(
          plugin_name: manifest.name, family: family.name, capability:,
          provider_name: declaration.provider, key: declaration.key, priority: manifest.prepare_priority
        )
        context = Syrus::Plugin::Context::RepoContext.new(repo_path:, repository:)
        reference.invoke do |provider|
          Array(provider.public_send(capability, context)).any? { |plan| !plan.respond_to?(:detected?) || plan.detected? }
        end
      end
    end
  end

  # Providers can be registered as either a class/instance that already
  # responds to `detect?` (a directly-registered preview_provider instance)
  # or a class that needs
  # instantiating first (preview_provider's instance-method form) —
  # mirrors Syrus::Plugin::PreviewProvider.instantiate.
  def provider_detects?(provider)
    instance = provider.respond_to?(:detect?) ? provider : provider.try(:new)
    instance.respond_to?(:detect?) && instance.detect?(repo_path)
  end
end
