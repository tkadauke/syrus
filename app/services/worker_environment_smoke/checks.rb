require "fileutils"
require "securerandom"
require "shellwords"
require "tmpdir"

class WorkerEnvironmentSmoke
  # The individual checks. Each answers `name` and
  # `call(shell:, env:) => { "status", "reason", "detail", "essential" }`,
  # where `env` is the forwarded child environment (see
  # WorkerEnvironmentSmoke#child_environment).
  #
  # `essential` checks are the ones every Run needs (the data root, temp space,
  # git). A worker failing one is broken; a worker failing only a non-essential
  # check (gh, the MySQL client) is degraded and keeps taking the work that does
  # not need it.
  #
  # `advisory` checks gate the rare work that needs them but are not worth an
  # operator's attention when they fail: gh, which the Linux worker image
  # leaves out on purpose and only break-glass GitHub access uses.
  module Checks
    DEFAULT_MIN_FREE_BYTES = 5 * 1024 * 1024 * 1024
    MIN_FREE_BYTES_ENV = "SYRUS_WORKER_SMOKE_MIN_FREE_BYTES".freeze
    COMMAND_TIMEOUT = 10
    COMPILE_TIMEOUT = 20
    AGENT_CLI_TIMEOUT = 20

    module Result
      module_function

      def passed(detail = nil, **extra)
        { "status" => PASSED, "detail" => detail }.merge(stringify(extra)).compact
      end

      def failed(reason, **extra)
        { "status" => FAILED, "reason" => reason }.merge(stringify(extra)).compact
      end

      def stringify(hash) = hash.transform_keys(&:to_s)
    end

    # A CLI that some workload shells out to: it must be on the forwarded PATH
    # and actually start (`--version` exits 0). "On PATH but broken" is the
    # common failure after a toolchain move -- a shim whose target is gone, a
    # binary linked against a library that was removed.
    class Command
      attr_reader :name

      def initialize(name:, argv:, essential: false, advisory: false, timeout: COMMAND_TIMEOUT)
        @name = name.to_s
        @argv = Array(argv).map(&:to_s)
        @essential = essential
        @advisory = advisory
        @timeout = timeout
      end

      def call(shell:, env:)
        result = shell.run(@argv, env: env, timeout: @timeout)
        return with_flag(Result.passed(first_line(result.output))) if result.success?

        with_flag(Result.failed(failure_reason(result)))
      end

      private

      def with_flag(hash)
        hash = hash.merge("essential" => @essential)
        @advisory ? hash.merge("advisory" => true) : hash
      end

      def failure_reason(result)
        command = @argv.first
        case result.status
        when "not_found" then "`#{command}` is not on PATH"
        when "not_executable" then "`#{command}` is on PATH but not executable"
        when "timed_out" then "`#{@argv.join(' ')}` did not finish within #{@timeout}s"
        else "`#{@argv.join(' ')}` exited #{result.exit_status}: #{last_line(result.output)}"
        end
      end

      def first_line(output) = output.to_s.lines.map(&:strip).find { |line| !line.empty? }

      def last_line(output) = output.to_s.lines.map(&:strip).reject(&:empty?).last.to_s[0, 300]
    end

    # Native gems build with the `ruby` the prepare command runs, through its
    # mkmf, with its configured compiler. A trivial try_link is exactly the
    # step every C extension's extconf takes first, so it is the cheapest
    # faithful answer to "would `bundle install` be able to build anything".
    class NativeExtension
      SCRIPT = <<~'RUBY'.freeze
        abort "a trivial C program does not compile and link with #{RbConfig::CONFIG['CC']}" unless try_link("int main(void) { return 0; }")
        puts RbConfig::CONFIG["CC"]
      RUBY

      def name = "c_compiler"

      def call(shell:, env:)
        Dir.mktmpdir("syrus-env-smoke-cc-") do |dir|
          result = shell.run([ "ruby", "-rmkmf", "-e", SCRIPT ], env: env, chdir: dir, timeout: COMPILE_TIMEOUT)
          next Result.passed(result.output.to_s.lines.last.to_s.strip, essential: false) if result.success?

          reason = result.status == "not_found" ? "`ruby` is not on PATH" : "native extension build failed: #{MkmfLog.tail(dir, result)}"
          Result.failed(reason, essential: false)
        end
      end
    end

    # mysql2's extconf finds a MySQL client through mysql_config (an explicit
    # --with-mysql-config/--with-mysql-dir build flag first, then PATH and a
    # fixed list of install locations), adds its --include and --libs, then
    # requires mysql.h, a linkable client library, and an rpath it can load
    # from. This repeats those steps -- including running the linked program,
    # which is where a client whose bundled OpenSSL went missing fails --
    # against whatever client the worker ends up with: a distro package, a
    # pinned download, anything. It validates the toolchain rather than one way
    # of installing it.
    class MysqlClient
      CONFIG_NAMES = %w[mysql_config mysql_config5 mariadb_config].freeze
      # mysql2's own fallback locations, after PATH (ext/mysql2/extconf.rb).
      FALLBACK_DIRS = %w[
        /opt /opt/local /opt/local/mysql /opt/local/lib/mysql5* /opt/homebrew/opt/mysql*
        /usr /usr/mysql /usr/local /usr/local/mysql /usr/local/mysql-* /usr/local/lib/mysql5*
        /usr/local/opt/mysql5* /usr/local/opt/mysql@* /usr/local/opt/mysql-client /usr/local/opt/mysql-client@*
      ].freeze
      SCRIPT = <<~'RUBY'.freeze
        config = ENV.fetch("PROBE_MYSQL_CONFIG")
        if RUBY_PLATFORM.include?("darwin") && system("command -v brew >/dev/null 2>&1")
          %w[openssl zstd].each do |formula|
            prefix = IO.popen(["brew", "--prefix", formula], err: File::NULL, &:read).to_s.strip
            $LIBPATH << "#{prefix}/lib" unless prefix.empty?
          end
        end
        includes = IO.popen([config, "--include"], &:read).to_s.strip
        abort "#{config} --include failed" unless $?.success?
        libs = IO.popen([config, "--libs"], &:read).to_s.strip
        abort "#{config} --libs failed" unless $?.success?
        $INCFLAGS << " " << includes
        $libs = "#{libs} #{$libs}"
        header = %w[mysql.h mysql/mysql.h].find { |candidate| have_header(candidate) }
        abort "mysql.h is not found with #{config} --include" unless header
        abort "the MySQL client library does not link with #{config} --libs" unless have_func("mysql_get_client_info", header)
        if (libdir = libs[%r{(-L)?(/[^ ]+)}, 2]) && RbConfig::CONFIG["RPATHFLAG"].to_s.empty? && try_link("int main() {return 0;}", " -Wl,-rpath,#{libdir}")
          $LDFLAGS << " -Wl,-rpath,#{libdir}"
        end
        abort "a program linked against the MySQL client library does not start (missing shared library?)" unless try_run("#include <#{header}>\nint main(void) { return mysql_get_client_info() ? 0 : 1; }")
        puts IO.popen([config, "--version"], &:read).to_s.strip
      RUBY

      def name = "mysql_client"

      def call(shell:, env:)
        config, source = locate(env)
        return Result.failed("no mysql_config found (build flag, PATH, or mysql2's default locations): mysql2 cannot find MySQL client headers and libraries", essential: false) unless config

        Dir.mktmpdir("syrus-env-smoke-mysql-") do |dir|
          result = shell.run([ "ruby", "-rmkmf", "-e", SCRIPT ], env: env.merge("PROBE_MYSQL_CONFIG" => config),
            chdir: dir, timeout: COMPILE_TIMEOUT)
          next Result.passed(result.output.to_s.lines.last.to_s.strip, mysql_config: config, mysql_config_source: source, essential: false) if result.success?

          reason = result.status == "not_found" ? "`ruby` is not on PATH" : "mysql2 build prerequisites failed: #{MkmfLog.tail(dir, result)}"
          Result.failed(reason, mysql_config: config, mysql_config_source: source, essential: false)
        end
      end

      private

      def locate(env)
        flag = build_flag_config(env["BUNDLE_BUILD__MYSQL2"])
        return [ flag, "BUNDLE_BUILD__MYSQL2" ] if flag

        CONFIG_NAMES.each do |config|
          found = Checks.which(config, env)
          return [ found, "PATH" ] if found
        end
        fallback = Dir["{#{FALLBACK_DIRS.map { |dir| "#{dir}/bin" }.join(',')}}/{#{CONFIG_NAMES.join(',')}}"].first
        fallback ? [ fallback, "default_location" ] : nil
      end

      def build_flag_config(flags)
        Shellwords.split(flags.to_s).each do |flag|
          key, value = flag.split("=", 2)
          return value if key == "--with-mysql-config" && value.to_s != ""
          return File.join(value, "bin", "mysql_config") if key == "--with-mysql-dir" && value.to_s != ""
        end
        nil
      rescue ArgumentError
        nil
      end
    end

    # The workflow data root holds every workspace and its lock. Workspaces
    # serialize on flock(2) under workflows/.locks, publish by rename, and
    # share prepared layers by hardlink -- a filesystem missing any of those
    # (some network and FUSE mounts return ENOTSUP for flock) fails every Run
    # that lands here, so this probes them on the real directory with a
    # uniquely named scratch file it removes again.
    class DataRoot
      def initialize(root:, min_free_bytes: nil)
        @root = root.to_s
        @min_free_bytes = min_free_bytes
      end

      def name = "workflow_data_root"

      def call(shell:, env:)
        return Result.failed("#{@root} does not exist", essential: true, path: @root) unless File.directory?(@root)
        return Result.failed("#{@root} is not writable", essential: true, path: @root) unless File.writable?(@root)

        dir = probe_directory
        semantics_error = filesystem_semantics_error(dir)
        return Result.failed(semantics_error, essential: true, path: dir) if semantics_error

        free = free_bytes(shell, dir, env)
        minimum = min_free_bytes(env)
        if free && free < minimum
          return Result.failed("only #{gib(free)} free under #{dir}; at least #{gib(minimum)} is required",
            essential: true, path: dir, available_bytes: free)
        end

        Result.passed("flock, hardlink and rename work#{free ? "; #{gib(free)} free" : ''}", essential: true, path: dir, available_bytes: free)
      end

      private

      # Where the real locks live when it exists; otherwise the nearest
      # existing directory below the root, so the check never creates the
      # layout itself.
      def probe_directory
        [ File.join(@root, "workflows", ".locks"), File.join(@root, "workflows"), @root ].find { |dir| File.directory?(dir) }
      end

      def filesystem_semantics_error(dir)
        base = File.join(dir, ".syrus-env-smoke-#{Process.pid}-#{SecureRandom.hex(4)}")
        link = "#{base}.link"
        renamed = "#{base}.renamed"
        step = "create a file"
        File.open(base, File::RDWR | File::CREAT | File::EXCL, 0o600) do |file|
          step = "flock"
          return "flock(LOCK_EX) is not available on #{dir}" unless file.flock(File::LOCK_EX | File::LOCK_NB)

          file.flock(File::LOCK_UN)
        end
        step = "hardlink"
        File.link(base, link)
        step = "rename"
        File.rename(link, renamed)
        return "rename did not preserve the hardlink on #{dir}" unless File.identical?(base, renamed)

        nil
      rescue SystemCallError => e
        "#{step} failed on #{dir}: #{e.class.name.split('::').last} (#{e.message})"
      ensure
        [ base, link, renamed ].each { |path| File.unlink(path) if path && File.exist?(path) rescue nil }
      end

      def free_bytes(shell, dir, env)
        result = shell.run([ "df", "-Pk", dir ], env: env, timeout: COMMAND_TIMEOUT)
        return nil unless result.success?

        kilobytes = result.output.to_s.lines.last.to_s.split[3]
        kilobytes&.match?(/\A\d+\z/) ? kilobytes.to_i * 1024 : nil
      end

      def min_free_bytes(env)
        return @min_free_bytes if @min_free_bytes

        configured = ENV[MIN_FREE_BYTES_ENV] || env[MIN_FREE_BYTES_ENV]
        configured.to_s.match?(/\A\d+\z/) ? configured.to_i : DEFAULT_MIN_FREE_BYTES
      end

      def gib(bytes) = format("%.1f GiB", bytes.to_f / (1024**3))
    end

    # Every agent, prepare command and grader writes to TMPDIR.
    class TempDir
      def name = "tmp"

      def call(shell:, env:)
        base = env["TMPDIR"].to_s.empty? ? Dir.tmpdir : env["TMPDIR"]
        Dir.mktmpdir("syrus-env-smoke-tmp-", base) do |dir|
          path = File.join(dir, "probe")
          File.write(path, "ok")
          return Result.failed("#{base} is writable but did not read back", essential: true, path: base) unless File.read(path) == "ok"
        end
        Result.passed(base, essential: true)
      rescue SystemCallError, IOError => e
        Result.failed("cannot use temp directory #{base}: #{e.class.name.split('::').last} (#{e.message})", essential: true, path: base)
      end
    end

    module MkmfLog
      module_function

      def tail(dir, result)
        return "timed out" if result.status == "timed_out"

        abort_line = result.output.to_s.lines.map(&:strip).reject(&:empty?).last.to_s
        log = File.join(dir, "mkmf.log")
        error = File.exist?(log) ? File.readlines(log).map(&:strip).grep(/error|not found|No such file/i).last.to_s : ""
        [ abort_line, error ].reject(&:empty?).uniq.join(" -- ")[0, 500]
      end
    end

    module_function

    def which(command, env)
      env["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
        path = File.join(dir, command)
        return path if File.file?(path) && File.executable?(path)
      end
      nil
    end

    # Core checks, then whatever the loaded plugins contribute. Each name is
    # what WorkerEnvironmentSmoke::Requirements asks for.
    def default(env:, data_root:)
      core(data_root:) + contributed
    end

    def core(data_root:)
      [
        DataRoot.new(root: data_root),
        TempDir.new,
        Command.new(name: "git", argv: %w[git --version], essential: true),
        Command.new(name: "ruby", argv: %w[ruby --version]),
        Command.new(name: "bundler", argv: %w[bundle --version]),
        Command.new(name: "node", argv: %w[node --version]),
        Command.new(name: "npm", argv: %w[npm --version]),
        Command.new(name: "gh", argv: %w[gh --version], advisory: true),
        NativeExtension.new,
        MysqlClient.new
      ]
    end

    # Rails-only: step kinds declare `worker_checks` (the browser plugin's
    # visual review needs playwright-mcp), and agent providers name the CLI
    # their agentic steps shell out to. Guarded so a misbehaving plugin
    # contributes nothing rather than taking the report down.
    def contributed
      step_kind_checks + agent_cli_checks
    end

    def step_kind_checks
      return [] unless defined?(Step::Kind) && Step::Kind.respond_to?(:entries)

      Step::Kind.entries.flat_map { |entry| Array(entry.respond_to?(:worker_checks) ? entry.worker_checks : nil) }
        .filter_map { |declared| command_from_declaration(declared) }
        .uniq(&:name)
    rescue StandardError
      []
    end

    def agent_cli_checks
      return [] unless defined?(Syrus::Plugin::ServiceProvider)

      Array(Syrus::Plugin::ServiceProvider.providers(:agent_provider)).filter_map do |provider|
        next unless provider.respond_to?(:worker_environment_check) && provider.respond_to?(:provider_key)

        argv = Array(provider.worker_environment_check).map(&:to_s)
        next if argv.empty?

        Command.new(name: agent_cli_check_name(provider.provider_key), argv: argv, timeout: AGENT_CLI_TIMEOUT)
      rescue StandardError
        nil
      end.uniq(&:name)
    rescue StandardError
      []
    end

    def agent_cli_check_name(provider_key) = "agent_cli_#{provider_key}"

    def command_from_declaration(declared)
      attrs = declared.to_h.transform_keys(&:to_s)
      name = attrs["name"].to_s
      argv = Array(attrs["command"]).map(&:to_s)
      return nil if name.empty? || argv.empty?

      Command.new(name: name, argv: argv, timeout: (attrs["timeout"] || COMMAND_TIMEOUT).to_i)
    end
  end
end
