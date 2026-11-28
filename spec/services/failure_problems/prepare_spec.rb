require "rails_helper"

RSpec.describe FailureProblems::Prepare do
  def failure(output_tail, exit_status: 5, **flags)
    {
      "command" => "bundle install --jobs 4",
      "exit_status" => exit_status,
      "timed_out" => false,
      "stopped" => false,
      "operator_killed" => false,
      "aliveness_failed" => false,
      "output_tail" => output_tail
    }.merge(flags.transform_keys(&:to_s))
  end

  def classify(...) = described_class.for(failure(...))

  # The tail a production worker without the zstd client library produced for
  # every mysql2 install, verbatim apart from the workspace path. It was
  # classified provider_transient (a wrapped backtrace frame read as
  # "temporary") and, on another run, timeout (the `timeout` gem's
  # "Fetching timeout 0.6.1"), and retried a dozen times an hour.
  def mysql2_zstd_tail = <<~TAIL
    Fetching timeout 0.6.1
    Installing timeout 0.6.1
    Fetching mysql2 0.5.7
    Installing mysql2 0.5.7 with native extensions
    Gem::Ext::BuildError: ERROR: Failed to build gem native extension.
    -----
    Setting libpath to /opt/homebrew/opt/mysql-client/lib
    -----
    creating Makefile
    compiling statement.c
    linking shared-object mysql2/mysql2.bundle
    ld: library 'zstd' not found
    clang: error: linker command failed with exit code 1 (use -v to see invocation)
    make: *** [mysql2.bundle] Error 1

    make failed, exit code 2

    Gem files will remain installed in
    /private/var/lib/syrus/workflows/1/vendor/bundle/ruby/3.4.0/gems/mysql2-0.5.7
    for inspection.
    /opt/syrus/rubies/3.4.10/lib/ruby/3.4.0/bundler/settings.rb:159:in
    'Bundler::Settings#temporary'

    An error occurred while installing mysql2 (0.5.7), and Bundler cannot continue.

    In Gemfile:
      mysql2
  TAIL

  # The change is fine: the same install passes on a worker that has zstd.
  # So it is the worker's defect, never the change's failure.
  it "declares a native extension that cannot link a system library the worker's missing dependency" do
    problem = classify(mysql2_zstd_tail)

    expect(problem.code).to eq("worker_environment_missing")
    expect(problem).to be_retryable
    expect(problem.evidence).to include(
      command: "bundle install --jobs 4",
      exit_status: 5,
      failure_kind: "missing_system_library",
      missing_kind: "library",
      missing_name: "zstd",
      failed_package: "mysql2 (0.5.7)"
    )
  end

  it "keeps a gem whose own source fails to compile against present libraries the repository's failure" do
    tail = <<~TAIL
      Installing broken_ext 0.1.0 with native extensions
      Gem::Ext::BuildError: ERROR: Failed to build gem native extension.
      compiling broken_ext.c
      broken_ext.c:12:3: error: use of undeclared identifier 'rb_frobnicate'
      make: *** [broken_ext.o] Error 1
      An error occurred while installing broken_ext (0.1.0), and Bundler cannot continue.
    TAIL

    problem = classify(tail)
    expect(problem.code).to eq("prepare_install_failed")
    expect(problem.evidence).to include(failure_kind: "native_extension", failed_package: "broken_ext (0.1.0)")
  end

  it "declares a shared library the worker cannot load a missing worker library" do
    tail = "node: error while loading shared libraries: libatomic.so.1: cannot open shared object file: No such file or directory"

    expect(classify(tail, exit_status: 127)).to have_attributes(code: "worker_environment_missing")
  end

  it "names the gem from Bundler's remaining-files notice when the summary line was cut off" do
    tail = mysql2_zstd_tail.split("An error occurred").first

    expect(classify(tail).evidence).to include(failed_package: "mysql2-0.5.7")
  end

  it "declares a missing C header a missing system library" do
    tail = <<~TAIL
      Installing pg 1.5.9 with native extensions
      compiling pg.c
      pg.h:14:10: fatal error: libpq-fe.h: No such file or directory
      An error occurred while installing pg (1.5.9), and Bundler cannot continue.
    TAIL

    problem = classify(tail)
    expect(problem.code).to eq("worker_environment_missing")
    expect(problem.evidence).to include(missing_kind: "header", missing_name: "libpq-fe.h", failed_package: "pg (1.5.9)")
  end

  it "declares an npm dependency-tree conflict a resolution failure" do
    tail = <<~TAIL
      npm error code ERESOLVE
      npm error ERESOLVE unable to resolve dependency tree
      npm error While resolving: app@1.0.0
      npm error Found: react@18.3.1
    TAIL

    problem = classify(tail, exit_status: 1)
    expect(problem.code).to eq("prepare_install_failed")
    expect(problem.evidence).to include(failure_kind: "dependency_resolution")
  end

  it "declares an out-of-sync package-lock a resolution failure" do
    tail = "npm error `npm ci` can only install packages when your package.json and package-lock.json or npm-shrinkwrap.json are in sync."

    expect(classify(tail, exit_status: 1).evidence).to include(failure_kind: "dependency_resolution")
  end

  it "declares a tool the worker does not have a missing worker executable" do
    problem = classify("bash: line 1: pnpm: command not found", exit_status: 127)

    expect(problem.code).to eq("worker_environment_missing")
    expect(problem.evidence).to include(failure_kind: "missing_executable", missing_kind: "executable", missing_name: "pnpm")
  end

  it "declares a bare exit 127 the missing program the prepare line starts with" do
    problem = described_class.for(failure("", exit_status: 127).merge("command" => "gh auth setup-git"))

    expect(problem.code).to eq("worker_environment_missing")
    expect(problem.evidence).to include(missing_name: "gh")
  end

  it "declares spawn ENOENT for a missing tool a missing worker executable" do
    problem = classify("npm error code ENOENT\nnpm error syscall spawn playwright-mcp\nnpm error path /work\n", exit_status: 1)

    expect(problem.code).to eq("worker_environment_missing")
    expect(problem.evidence).to include(missing_name: "playwright-mcp")
  end

  # A script the repository itself should contain is the repository's
  # problem, not the worker's.
  it "keeps a missing repository-relative script the repository's failure" do
    problem = classify("bash: line 1: bin/setup-deps: No such file or directory", exit_status: 127)

    expect(problem.code).to eq("prepare_install_failed")
    expect(problem.evidence).to include(failure_kind: "missing_executable", subject: "bin/setup-deps")
  end

  it "declares an npm registry connection reset a retryable network failure" do
    tail = <<~TAIL
      npm warn deprecated @github/webauthn-json@2.1.1: Deprecated: Modern browsers support built-in WebAuthn JSON methods.
      npm error code ECONNRESET
      npm error network aborted
      npm error network This is a problem related to network connectivity.
    TAIL

    problem = classify(tail, exit_status: 1)
    expect(problem.code).to eq("prepare_network_transient")
    expect(problem).to be_retryable
    expect(problem.evidence[:network_error]).to eq("ECONNRESET")
  end

  it "declares a RubyGems fetch timeout a retryable network failure" do
    tail = <<~TAIL
      Fetching source index from https://rubygems.org/
      Retrying fetcher due to error (2/4): Bundler::HTTPError Could not fetch specs from https://rubygems.org/ due to underlying error <Net::OpenTimeout: Failed to open TCP connection to rubygems.org:443 (execution expired)>
    TAIL

    expect(classify(tail).code).to eq("prepare_network_transient")
  end

  it "declares a registry 5xx a retryable network failure" do
    tail = "npm error 503 Service Unavailable - GET https://registry.npmjs.org/left-pad"

    expect(classify(tail, exit_status: 1).code).to eq("prepare_network_transient")
  end

  it "declares DNS failures retryable" do
    tail = "Could not fetch specs from https://rubygems.org/ due to underlying error <Gem::RemoteFetcher::UnknownHostError: getaddrinfo: Temporary failure in name resolution>"

    expect(classify(tail).code).to eq("prepare_network_transient")
  end

  # pip prints "No matching distribution" for a package that does not exist,
  # and also when it could not reach the index at all.
  it "reads an ambiguous 'not found' as network when the tail shows the connection failing" do
    tail = <<~TAIL
      WARNING: Retrying (Retry(total=0)) after connection broken by 'NewConnectionError('<urllib3.connection.HTTPSConnection object>: Failed to establish a new connection: [Errno 111] Connection refused')': /simple/requests/
      ERROR: Could not find a version that satisfies the requirement requests (from versions: none)
      ERROR: No matching distribution found for requests
    TAIL

    expect(classify(tail, exit_status: 1).code).to eq("prepare_network_transient")
  end

  it "reads the same 'not found' as deterministic when nothing failed to connect" do
    tail = <<~TAIL
      ERROR: Could not find a version that satisfies the requirement no-such-package==9.9 (from versions: none)
      ERROR: No matching distribution found for no-such-package==9.9
    TAIL

    problem = classify(tail, exit_status: 1)
    expect(problem.code).to eq("prepare_install_failed")
    expect(problem.evidence).to include(failed_package: "no-such-package==9.9")
  end

  it "declares a timed-out command a retryable timeout" do
    problem = classify("Installing nokogiri 1.19.7\n", exit_status: nil, timed_out: true, duration_s: 600.0)

    expect(problem.code).to eq("timeout")
    expect(problem).to be_retryable
    expect(problem.evidence).to include(timed_out: true, duration_s: 600.0)
  end

  it "declares a process that disappeared a worker death" do
    expect(classify("", exit_status: nil, aliveness_failed: true).code).to eq("worker_died")
  end

  it "declares local disk exhaustion disk_full" do
    expect(classify("npm error code ENOSPC\nnpm error syscall write", exit_status: 1).code).to eq("disk_full")
  end

  it "makes no claim about a command an operator or the run stopped" do
    expect(classify("", exit_status: nil, stopped: true)).to be_nil
    expect(classify("", exit_status: nil, operator_killed: true)).to be_nil
  end

  # It already failed twice in a row with nothing pointing at the network.
  it "declares an unrecognized failure a non-retryable install failure with the last error line" do
    problem = classify("something went sideways\nerror: unexpected thing happened\ndone", exit_status: 2)

    expect(problem.code).to eq("prepare_install_failed")
    expect(problem.evidence).to include(failure_kind: "unrecognized", error_line: "error: unexpected thing happened")
  end

  it "does not read a `timeout` or `temporary` package name as a timed-out or transient install" do
    tail = "Fetching timeout 0.6.1\nInstalling temporary_tables 1.0\nAn error occurred while installing broken (1.0), and Bundler cannot continue.\n"

    problem = classify(tail)
    expect(problem.code).to eq("prepare_install_failed")
    expect(problem.evidence).to include(failed_package: "broken (1.0)")
  end
end
