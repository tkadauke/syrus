module FailureProblems
  # Classifies one failed dependency-install / setup command from its exit
  # status and its own output tail. Called by Steps::Prepare and
  # ImmutableSourceCheckout with the payload they already record for the
  # operator (see Steps::Prepare#prepare_failure_payload), after the
  # command's in-step retry -- so a failure that reaches this point has
  # already failed twice.
  #
  # Order matters, and is from most to least specific:
  #
  #   1. stopped / killed       -- not the command's fault; no claim
  #   2. process disappeared    -- worker_died
  #   3. timed out              -- timeout (retryable within the retry budget)
  #   4. disk full              -- disk_full
  #   5. deterministic build    -- prepare_install_failed (compile, link,
  #                                missing library, lockfile resolution,
  #                                missing executable). Checked before the
  #                                network patterns because a failed build
  #                                prints download lines ("Fetching ...")
  #                                that can look like network activity.
  #   6. registry network       -- prepare_network_transient
  #   7. ambiguous "not found"  -- prepare_install_failed, unless (6) matched
  #   8. anything else          -- prepare_install_failed (unrecognized): a
  #                                command that failed twice in a row, with
  #                                no network evidence, is not noise.
  module Prepare
    module_function

    # Failures that only a change to the repository or the worker fixes.
    # Each entry is [failure_kind, pattern]; the first capture group, when
    # present, names the package or library involved.
    DETERMINISTIC_PATTERNS = [
      # Native extensions: RubyGems, node-gyp, Python wheels, generic make/ld.
      [ "missing_system_library", /ld: library '([^']+)' not found/ ],
      [ "missing_system_library", /cannot find -l(\S+)/ ],
      [ "missing_system_library", /fatal error: ([\w\/.+-]+\.h): No such file or directory/ ],
      [ "missing_system_library", /fatal error: '([\w\/.+-]+\.h)' file not found/ ],
      [ "missing_system_library", /Package '?([\w.+-]+)'?,? (?:was not found in the pkg-config search path|required by .* not found)/ ],
      [ "missing_system_library", /\b(mysql_config|pg_config) (?:not found|is not in PATH)|Can't find the '([\w.+-]+)' library/i ],
      [ "native_extension", /Failed to build gem native extension/ ],
      [ "native_extension", /Gem::Ext::BuildError/ ],
      [ "native_extension", /^make(?:\[\d+\])?: \*\*\* .*Error \d+/ ],
      [ "native_extension", /linker command failed with exit code/ ],
      [ "native_extension", /gyp ERR! (?:build error|stack Error: `make` failed)/ ],
      [ "native_extension", /Failed building wheel for (\S+)/ ],
      [ "native_extension", /error: subprocess-exited-with-error/ ],
      # Resolution: the manifest and the lockfile do not describe one install.
      [ "dependency_resolution", /npm (?:ERR!|error) code ERESOLVE/ ],
      [ "dependency_resolution", /npm (?:ERR!|error) code ETARGET/ ],
      [ "dependency_resolution", /npm (?:ERR!|error) code E404/ ],
      [ "dependency_resolution", /`npm ci` can only install packages when your package\.json and package-lock\.json/ ],
      [ "dependency_resolution", /ERR_PNPM_(?:OUTDATED_LOCKFILE|LOCKFILE_\w+|NO_MATCHING_VERSION|FROZEN_LOCKFILE\w*)/ ],
      [ "dependency_resolution", /The lockfile would have been modified by this install, which is explicitly forbidden|YN0028/ ],
      [ "dependency_resolution", /Your lockfile needs to be updated, but yarn was run with `--frozen-lockfile`/ ],
      [ "dependency_resolution", /Bundler could not find compatible versions|Could not find compatible versions|version solving has failed/i ],
      [ "dependency_resolution", /The gemspecs for path gems changed|You are trying to install in deployment mode after changing/ ],
      [ "dependency_resolution", /Your bundle is locked to (\S+)/ ],
      [ "dependency_resolution", /ResolutionImpossible|Cannot install .* because these package versions have conflicting dependencies/ ],
      [ "dependency_resolution", /poetry\.lock .*(?:not consistent|was last generated)|pyproject\.toml changed significantly since poetry\.lock/ ],
      [ "dependency_resolution", /Gemfile\.lock.*(?:merge conflict|corrupt)|Your Gemfile\.lock contains merge conflicts/ ],
      # A command or binary that does not exist on this worker.
      [ "missing_executable", /(?:bash|sh): (?:line \d+: |\d+: )?([\w.\/-]+): (?:command )?not found/ ],
      [ "missing_executable", /npm (?:ERR!|error) syscall spawn (\S+)/ ],
      [ "missing_executable", /spawn (\S+) ENOENT/ ]
    ].freeze

    # Statements that a package could not be found that a registry outage can
    # also produce (pip prints "No matching distribution" when it is offline).
    # Only deterministic once the network patterns have had their say.
    AMBIGUOUS_NOT_FOUND_PATTERNS = [
      [ "dependency_resolution", /Could not find gem '([^']+)'/ ],
      [ "dependency_resolution", /Could not find ([\w.-]+-[\d.]+\S*) in (?:any of the sources|locally installed gems)/ ],
      [ "dependency_resolution", /No matching distribution found for (\S+)/ ],
      [ "dependency_resolution", /No matching version found for (\S+)/ ]
    ].freeze

    # The registry, the network or TLS between us and it -- the same command
    # succeeds once the connection does. Anchored on error identifiers and
    # client error classes rather than on words like "temporary" or
    # "timeout", which appear in package names and backtraces.
    NETWORK_PATTERN = %r{
      \b(?:ECONNRESET|ETIMEDOUT|ESOCKETTIMEDOUT|ECONNREFUSED|ECONNABORTED|EAI_AGAIN|ENOTFOUND|ENETUNREACH|EHOSTUNREACH|EPIPE)\b|
      socket\ hang\ up|
      npm\ (?:ERR!|error)\ network|
      npm\ (?:ERR!|error)\ code\ E5\d\d|
      npm\ (?:ERR!|error)\ 5\d\d\b|
      Gem::RemoteFetcher::(?:FetchError|UnknownHostError)|
      Bundler::(?:HTTPError|Fetcher::(?:NetworkDownError|FallbackError|CertificateFailureError))|
      Net::(?:OpenTimeout|ReadTimeout)|
      Errno::(?:ECONNRESET|ECONNREFUSED|ETIMEDOUT|EHOSTUNREACH|ENETUNREACH)|
      Could\ not\ fetch\ specs\ from|
      Retrying\ (?:fetcher|download\ gem\ from|dependency\ api)\ due\ to\ error|
      Network\ error\ while\ fetching|
      could\ not\ resolve\ host|
      Temporary\ failure\ in\ name\ resolution|
      getaddrinfo|
      nodename\ nor\ servname\ provided|
      connection\ (?:reset\ by\ peer|refused|timed\ out)|
      SSL_connect\ returned|
      SSL_ERROR_SYSCALL|
      TLS\ handshake\ timeout|
      (?:NewConnectionError|ConnectTimeoutError|ReadTimeoutError|ProtocolError|RemoteDisconnected)|
      Bad\ response:\ 5\d\d|
      (?:status\ code|HTTP\ status|returned\ error:?)\ 5\d\d|
      \b5\d\d\ (?:Internal\ Server\ Error|Bad\ Gateway|Service\ Unavailable|Gateway\ Time-?out)\b|
      error\ sending\ request\ for\ url
    }ix

    # Bundler names the gem whose install failed on the line that ends the
    # run; npm names the package directory it was building.
    PACKAGE_PATTERNS = [
      /An error occurred while installing (\S+ \([^)]+\))/,
      /Gem files will remain installed in\s+\S*\/gems\/(\S+?)\s+for inspection/,
      /npm (?:ERR!|error) path \S*\/node_modules\/((?:@[\w.-]+\/)?[\w.-]+)/,
      /Failed building wheel for (\S+)/,
      /No matching version found for (\S+)/,
      /No matching distribution found for (\S+)/,
      /Could not find gem '([^']+)'/
    ].freeze

    MISSING_EXECUTABLE_EXIT = 127

    def for(failure)
      failure = failure.to_h.stringify_keys
      return nil if failure["stopped"] || failure["operator_killed"]

      tail = failure["output_tail"].to_s
      base = { command: failure["command"], exit_status: failure["exit_status"] }

      return FailureProblems.declare(:worker_died, base.merge(aliveness_failed: true)) if failure["aliveness_failed"]
      return FailureProblems.declare(:timeout, base.merge(timed_out: true, duration_s: failure["duration_s"])) if failure["timed_out"]
      return FailureProblems.declare(:disk_full, base) if tail.match?(Steps::Base::DISK_FULL_PATTERN)

      if (match = first_match(DETERMINISTIC_PATTERNS, tail))
        return install_failed(base, tail, *match)
      end

      if (network = tail[NETWORK_PATTERN])
        return FailureProblems.declare(:prepare_network_transient, base.merge(network_error: network.strip.truncate(200)))
      end

      if (match = first_match(AMBIGUOUS_NOT_FOUND_PATTERNS, tail))
        return install_failed(base, tail, *match)
      end

      if failure["exit_status"].to_i == MISSING_EXECUTABLE_EXIT
        return install_failed(base, tail, "missing_executable", nil)
      end

      install_failed(base, tail, "unrecognized", nil)
    end

    def first_match(patterns, tail)
      patterns.each do |kind, pattern|
        match = tail.match(pattern)
        next unless match

        return [ kind, match.captures.compact.first ]
      end
      nil
    end

    def install_failed(base, tail, kind, subject)
      evidence = base.merge(
        failure_kind: kind,
        failed_package: failed_package(tail),
        subject: subject,
        error_line: error_line(tail)
      )
      FailureProblems.declare(:prepare_install_failed, evidence)
    end

    def failed_package(tail)
      PACKAGE_PATTERNS.each do |pattern|
        match = tail.match(pattern)
        return match[1] if match
      end
      nil
    end

    # The line an operator would quote: the last one that says error/failed.
    def error_line(tail)
      tail.lines.reverse_each do |line|
        stripped = line.strip
        return stripped.truncate(300) if stripped.match?(/\b(?:error|failed|fatal|not found|cannot)\b/i)
      end
      nil
    end
  end
end
