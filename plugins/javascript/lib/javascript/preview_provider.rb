require "json"
require "pathname"

module JavaScript
  # :preview_provider for Node/JS (and TS) repositories: `package.json`'s
  # `scripts` object is a close-to-universal convention for "how do I run
  # this" across the JS/TS ecosystem, unlike Python or Go.
  class PreviewProvider
    SCRIPT_KEYS = %w[dev start].freeze

    # Selects the run script at shell time (not Ruby time): providers are
    # stateless between #detect? and #start_command (see
    # Syrus::Plugin::PreviewProvider), so the dev/start choice has to be made
    # by the process that actually has the repo checked out as its cwd.
    SCRIPT_SELECTOR = %q{node -e "const s=(require('./package.json').scripts||{});process.stdout.write(s.dev?'dev':'start')"}.freeze

    def detect?(repo_path)
      SCRIPT_KEYS.any? { |key| scripts(repo_path).key?(key) }
    end

    # Prefers `scripts.dev`, falling back to `scripts.start`. Most JS dev
    # servers honor a PORT env var (Vite, webpack-dev-server, Next.js, etc.);
    # a few need a repo-level config tweak to actually bind to it, so this is
    # a documented convention rather than a universal guarantee (unlike
    # `${PORT}`/`$PORT` substitution in `.syrus.yml`'s explicit `preview:`
    # section, see PreviewCommandSource#from_syrus_yml).
    def start_command(port:)
      "PORT=#{port} npm run $(#{SCRIPT_SELECTOR})"
    end

    # Reuses JavaScript::PrepareDetector's lockfile priority so the two
    # extension points never disagree about which package manager to run.
    def setup_commands
      [ JavaScript::PrepareDetector.shell_install_command ]
    end

    private

    def scripts(repo_path)
      package_json = Pathname.new(repo_path).join("package.json")
      return {} unless package_json.exist?

      data = JSON.parse(package_json.read)
      data.is_a?(Hash) && data["scripts"].is_a?(Hash) ? data["scripts"] : {}
    rescue JSON::ParserError
      {}
    end
  end
end
