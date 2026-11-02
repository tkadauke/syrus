require "rails_helper"

# The production image builds with BUNDLE_WITHOUT="development:test", so a gem
# that only reaches the bundle as a transitive dependency of a development gem
# is absent at runtime. Plugin `app/` code is eager-loaded when the plugin is
# enabled, so a `require` of such a gem raises LoadError during boot and every
# pod crashloops -- while the local suite and any instance that happens to have
# the plugin disabled stay green.
#
# That is exactly how a terminal screen service shipped a `require
# "unicode/display_width"`: the gem arrives transitively via RuboCop, which is
# development-only. The fix is to declare it in the plugin's own gemspec, which
# is what `Syrus.plugin_gemspec`'s block argument exists for.
RSpec.describe "plugin gem requires" do
  # Only runtime code. Spec files legitimately require test-only gems, and
  # plugins/*/spec never ships in the image.
  RUNTIME_GLOB = "plugins/*/{app,lib}/**/*.rb".freeze
  REQUIRE = /^[[:space:]]*require\s+["']([a-z0-9_\/.-]+)["']/

  # Directories a `require` may legitimately resolve against in production: the
  # groups the image actually installs, the stdlib, and Ruby's default gems.
  # BUNDLE_WITHOUT names development and test, so :production counts here --
  # that is where the MySQL adapter and the S3 client live.
  BUNDLED_GROUPS = %i[default production].freeze

  def production_load_paths
    @production_load_paths ||= begin
      bundled = Bundler.definition.specs_for(BUNDLED_GROUPS.dup).flat_map(&:full_require_paths)
      stdlib = [ RbConfig::CONFIG["rubylibdir"], RbConfig::CONFIG["archdir"] ].compact
      defaults = Gem::Specification.select(&:default_gem?).flat_map(&:full_require_paths)
      (bundled + stdlib + defaults).uniq
    end
  end

  # Plugins and the host app put their own code on the load path at boot, so a
  # require that names a sibling file inside any plugin's lib/ or the app's own
  # lib/ is satisfied without a gem.
  def first_party_load_paths
    @first_party_load_paths ||=
      Dir[Rails.root.join("plugins/*/lib")].map(&:to_s) + [ Rails.root.join("lib").to_s ]
  end

  def resolvable?(target)
    (production_load_paths + first_party_load_paths).any? do |dir|
      File.exist?(File.join(dir, "#{target}.rb")) ||
        Dir.glob(File.join(dir, "#{target}.{so,bundle}")).any?
    end
  end

  it "has runtime plugin code to check" do
    expect(Dir[Rails.root.join(RUNTIME_GLOB)]).not_to be_empty
  end

  it "resolve against the production bundle" do
    offenders = Dir[Rails.root.join(RUNTIME_GLOB)].flat_map do |file|
      relative = Pathname(file).relative_path_from(Rails.root).to_s

      File.readlines(file).each_with_index.filter_map do |line, index|
        target = line[REQUIRE, 1]
        next if target.nil? || resolvable?(target)

        "#{relative}:#{index + 1}: require \"#{target}\""
      end
    end

    expect(offenders).to be_empty, <<~MESSAGE
      This plugin code requires a gem that is missing from the production
      bundle (the image builds with BUNDLE_WITHOUT="development:test"), so
      enabling the plugin crashloops every pod at boot with LoadError.

      Declare the gem in the plugin's gemspec:

        Syrus.plugin_gemspec(__FILE__) do |spec|
          spec.add_dependency "the-gem", "~> 1.0"
        end

      then run `bundle install` to update Gemfile.lock.

      #{offenders.join("\n")}
    MESSAGE
  end
end
