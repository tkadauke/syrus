# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "spec_helper"

# uninstall.sh removes everything install.sh (and the desktop app) put on the
# machine: the compose stack + volumes (enumerated by compose project label,
# verified by re-listing), the syrus images (exact repository basename, plain
# rmi — never -f), ~/.syrus/local (the encryption keys! deleted only once the
# data volumes are verifiably gone), ~/.syrus/credentials, the CLI, the Claude
# skill, the app bundle (plus a validated --app-path bundle), and the app
# settings. Anything that could not be removed or verified is reported
# honestly — failed step events and exit code 3 — never as false success.
# Dynamic examples run the real script against a sandboxed $HOME and stubbed
# `docker`/`uname` binaries — no daemon, no side effects, fast. uninstall.ps1
# is its Windows port; PowerShell isn't available on the mac/linux CI hosts,
# so its section is a static parity contract in the style of
# install_parity_spec.rb.
RSpec.describe "uninstall scripts" do
  let(:repo_root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(repo_root, "uninstall.sh") }
  let(:script_text) { File.read(script, encoding: "UTF-8") }
  let(:ps1) { File.read(File.join(repo_root, "uninstall.ps1"), encoding: "UTF-8") }

  def run_uninstall(*args, home:, stub_dir: nil)
    path = [stub_dir, "/usr/bin", "/bin"].compact.join(":")
    env = { "PATH" => path, "HOME" => home }
    Open3.capture3(env, "bash", script, *args)
  end

  # Pin the platform to macOS regardless of the host the suite runs on (the
  # Ruby suite runs inside a Linux container on some dev machines).
  def write_uname_stub(dir)
    File.write(File.join(dir, "uname"), "#!/bin/bash\necho Darwin\n")
    File.chmod(0o755, File.join(dir, "uname"))
  end

  # A fake `docker` that records every invocation and keeps STATE: containers
  # and volumes live in text files, `rm`/`volume rm` empty them, and the
  # re-list/verify calls (`ps`, `volume ls`, `volume inspect`) read them — so
  # the script's teardown verification is exercised for real. The image list
  # includes adversarial rows: `my-syrus-backend` (basename mismatch — must
  # never be removed) and a registry:port-prefixed syrus-backend (must be).
  #
  #   stuck_volumes: `volume rm` fails and leaves the volumes in place —
  #                  drives the honest-failure / keys-preservation path.
  #   rmi_fails:     every `rmi` refuses (image in use) — drives the
  #                  "left in place, not counted as removed" path.
  def write_docker_stub(dir, daemon_up: true, stuck_volumes: false, rmi_fails: false)
    calls = File.join(dir, "calls.log")
    containers = File.join(dir, "containers.txt")
    volumes = File.join(dir, "volumes.txt")
    File.write(containers, "cid-web\ncid-worker\ncid-setup\n")
    File.write(volumes, "syrus_syrus-data\nsyrus_syrus-search\n")
    volume_rm_body =
      if stuck_volumes
        "exit 1"
      else
        <<~RM.strip
          shift 2
                for v in "$@"; do
                  grep -vx "$v" "#{volumes}" > "#{volumes}.tmp" || true
                  mv "#{volumes}.tmp" "#{volumes}"
                done
                exit 0
        RM
      end
    stub = File.join(dir, "docker")
    File.write(stub, <<~SH)
      #!/bin/bash
      echo "$*" >> "#{calls}"
      case "$1" in
        info) exit #{daemon_up ? 0 : 1} ;;
        compose) exit 0 ;;
        ps) cat "#{containers}" 2>/dev/null; exit 0 ;;
        rm) : > "#{containers}"; exit 0 ;;
        images)
          printf 'ghcr.io/tkadauke/syrus-backend 0.1.2\\nghcr.io/someone/syrus-local dev-abc\\nregistry.example.com:5000/fork/syrus-backend latest\\nmy-syrus-backend latest\\nnginx latest\\n'
          exit 0 ;;
        rmi) exit #{rmi_fails ? 1 : 0} ;;
        volume)
          case "$2" in
            ls) cat "#{volumes}" 2>/dev/null; exit 0 ;;
            inspect) grep -qx "$3" "#{volumes}" 2>/dev/null; exit $? ;;
            rm)
              #{volume_rm_body} ;;
          esac ;;
      esac
      exit 0
    SH
    File.chmod(0o755, stub)
  end

  # A docker binary that behaves as if nothing is installed (every call dies
  # immediately). Shadowing — rather than omitting — the binary matters: the
  # script hardens PATH with /usr/local/bin etc., so a host with real docker
  # would otherwise leak into the test and actually tear its stack down.
  def write_dead_docker_stub(dir)
    stub = File.join(dir, "docker")
    File.write(stub, "#!/bin/bash\necho \"$*\" >> \"#{File.join(dir, "calls.log")}\"\nexit 127\n")
    File.chmod(0o755, stub)
  end

  def stub_calls(stub_dir)
    path = File.join(stub_dir, "calls.log")
    File.exist?(path) ? File.readlines(path, chomp: true) : []
  end

  def parse_events(stdout)
    stdout.lines.map { |line| JSON.parse(line) }
  end

  # Lay down every artifact install.sh + the desktop app create (macOS shape,
  # matching the pinned `uname`).
  def populate_home(home)
    state_dir = File.join(home, ".syrus", "local")
    FileUtils.mkdir_p(state_dir)
    File.write(File.join(state_dir, ".env"), "SECRET_KEY_BASE=abc\n")
    File.write(File.join(state_dir, "docker-compose.yml"), "name: syrus\n")
    File.write(File.join(home, ".syrus", "credentials"), "url + token\n")
    FileUtils.mkdir_p(File.join(home, ".local", "bin"))
    File.write(File.join(home, ".local", "bin", "syrus"), "#!/bin/bash\n")
    FileUtils.mkdir_p(File.join(home, ".claude", "skills", "syrus"))
    File.write(File.join(home, ".claude", "skills", "syrus", "SKILL.md"), "# syrus\n")
    FileUtils.mkdir_p(File.join(home, "Applications", "Syrus.app", "Contents"))
    FileUtils.mkdir_p(File.join(home, "Library", "Application Support", "Syrus"))
    File.write(File.join(home, "Library", "Application Support", "Syrus", "settings.json"), "{}\n")
  end

  describe "uninstall.sh" do
    it "passes a bash syntax check and is executable" do
      _out, err, status = Open3.capture3("bash", "-n", script)
      expect(status.exitstatus).to eq(0), err
      expect(File.executable?(script)).to be(true)
    end

    it "documents the flags, the y/N gate, and the exit codes in --help" do
      Dir.mktmpdir do |home|
        out, _err, status = run_uninstall("--help", home: home)
        expect(status.exitstatus).to eq(0)
        %w[--yes --keep-data --json --app-path --help].each { |flag| expect(out).to include(flag) }
        expect(out).to include("Exit codes:")
        expect(out).to include("3 partial")
        expect(out).to include("ENCRYPTION KEYS")
      end
      # The interactive prompt is a real one-question y/N gate.
      expect(script_text).to include('read -r -p "Remove Syrus from this machine? [y/N] "')
    end

    it "refuses to run unconfirmed outside a terminal instead of assuming yes" do
      Dir.mktmpdir do |stub_dir|
        Dir.mktmpdir do |home|
          write_uname_stub(stub_dir)
          populate_home(home)
          out, err, status = run_uninstall("--json", "--help", home: home) # sanity: --help still wins
          expect(status.exitstatus).to eq(0)
          expect(out).to include("--keep-data")
          expect(err).to eq("")

          _out, err, status = run_uninstall(home: home, stub_dir: stub_dir)
          expect(status.exitstatus).to eq(2)
          expect(err).to include("--yes")
          # Nothing was removed by the refused run.
          expect(File.exist?(File.join(home, ".syrus", "credentials"))).to be(true)
        end
      end
    end

    it "removes the stack, volumes (verified by re-listing), images, and every file artifact with --yes/--json" do
      Dir.mktmpdir do |stub_dir|
        Dir.mktmpdir do |home|
          write_uname_stub(stub_dir)
          write_docker_stub(stub_dir)
          populate_home(home)

          out, _err, status = run_uninstall("--json", home: home, stub_dir: stub_dir)
          expect(status.exitstatus).to eq(0)

          events = parse_events(out)
          expect(events.first).to include("event" => "start", "mode" => "uninstall", "keep_data" => false)
          expect(events.last).to include("event" => "done")
          step_ids = events.select { |e| e["event"] == "step" }.map { |e| e["id"] }
          expect(step_ids).to include(
            "docker_down", "docker_images", "state_dir", "credentials", "cli", "skill",
            "desktop_app", "app_settings"
          )
          expect(step_ids).not_to include("desktop_app_custom") # only with --app-path
          # Success is claimed only after the re-list verified a clean teardown,
          # which is also what unlocks deleting the encryption keys.
          expect(events).to include(hash_including("event" => "step", "id" => "docker_down", "status" => "ok"))
          expect(events).to include(hash_including("event" => "step", "id" => "state_dir", "status" => "ok"))

          calls = stub_calls(stub_dir)
          down = calls.grep(/\Acompose /).grep(/ down /)
          expect(down.length).to eq(1)
          expect(down.first).to include("-p syrus")
          expect(down.first).to include("-f #{File.join(home, ".syrus", "local", "docker-compose.yml")}")
          expect(down.first).to include("down -v --remove-orphans")
          # Containers are enumerated by compose project label (covers v1
          # syrus_web_1 and v2 syrus-web-1 names) and removed by ID — then the
          # listing is repeated to verify.
          expect(calls).to include("ps -aq --filter label=com.docker.compose.project=syrus")
          expect(calls.grep(/\Aps -aq --filter/).length).to be >= 2
          expect(calls).to include("rm -f cid-web cid-worker cid-setup")
          # Volumes by label PLUS the known names as a fallback, then verified.
          expect(calls).to include("volume ls -q --filter label=com.docker.compose.project=syrus")
          expect(calls).to include("volume inspect syrus_syrus-data")
          expect(calls).to include("volume rm syrus_syrus-data syrus_syrus-search")
          # Images are removed per repo:tag with a plain rmi — never -f (that
          # would untag every tag sharing the ID) — matched by exact repository
          # basename under any registry; my-syrus-backend and nginx survive.
          expect(calls).to include("rmi ghcr.io/tkadauke/syrus-backend:0.1.2")
          expect(calls).to include("rmi ghcr.io/someone/syrus-local:dev-abc")
          expect(calls).to include("rmi registry.example.com:5000/fork/syrus-backend:latest")
          expect(calls.grep(/\Armi -f/)).to be_empty
          expect(calls.grep(/\Armi /).grep(/my-syrus-backend|nginx/)).to be_empty

          expect(Dir.exist?(File.join(home, ".syrus"))).to be(false)
          expect(File.exist?(File.join(home, ".local", "bin", "syrus"))).to be(false)
          expect(Dir.exist?(File.join(home, ".claude", "skills", "syrus"))).to be(false)
          expect(Dir.exist?(File.join(home, "Applications", "Syrus.app"))).to be(false)
          expect(Dir.exist?(File.join(home, "Library", "Application Support", "Syrus"))).to be(false)
        end
      end
    end

    it "preserves ~/.syrus, the volumes, and the app settings with --keep-data" do
      Dir.mktmpdir do |stub_dir|
        Dir.mktmpdir do |home|
          write_uname_stub(stub_dir)
          write_docker_stub(stub_dir)
          populate_home(home)

          out, _err, status = run_uninstall("--json", "--keep-data", home: home, stub_dir: stub_dir)
          expect(status.exitstatus).to eq(0)

          events = parse_events(out)
          expect(events.first).to include("event" => "start", "keep_data" => true)
          skipped = events.select { |e| e["event"] == "step" && e["status"] == "skipped" }.map { |e| e["id"] }
          expect(skipped).to include("state_dir", "credentials", "app_settings")

          calls = stub_calls(stub_dir)
          down = calls.grep(/\Acompose /).grep(/ down/)
          expect(down.first).to include("down --remove-orphans")
          expect(down.first).not_to include(" -v ")
          # Volumes are never enumerated, removed, or even inspected.
          expect(calls.grep(/\Avolume /)).to be_empty
          # Containers and images still go.
          expect(calls).to include("rm -f cid-web cid-worker cid-setup")
          expect(calls).to include("rmi ghcr.io/tkadauke/syrus-backend:0.1.2")
          expect(File.exist?(File.join(home, ".syrus", "local", ".env"))).to be(true)
          expect(File.exist?(File.join(home, ".syrus", "credentials"))).to be(true)
          expect(Dir.exist?(File.join(home, "Library", "Application Support", "Syrus"))).to be(true)
          expect(File.exist?(File.join(home, ".local", "bin", "syrus"))).to be(false)
          expect(Dir.exist?(File.join(home, "Applications", "Syrus.app"))).to be(false)
        end
      end
    end

    it "keeps the encryption keys and exits 3 when docker is unreachable, and stays safe to re-run" do
      Dir.mktmpdir do |stub_dir|
        Dir.mktmpdir do |home|
          write_uname_stub(stub_dir)
          write_dead_docker_stub(stub_dir)
          populate_home(home)

          out, err, status = run_uninstall("--json", home: home, stub_dir: stub_dir)
          # Partial success: the volumes could not be removed or verified.
          expect(status.exitstatus).to eq(3)
          events = parse_events(out)
          expect(events).to include(
            hash_including("event" => "step", "id" => "docker_down", "status" => "skipped")
          )
          expect(events).to include(
            hash_including("event" => "log", "stream" => "docker",
              "line" => "docker unavailable; skipping container, volume, and image removal")
          )
          # The state dir is PRESERVED: deleting the .env encryption keys while
          # syrus_syrus-data may survive would wedge reinstall (install.sh's
          # exit-20 guard) with no compose file left to run `down -v` either.
          expect(events).to include(
            hash_including("event" => "step", "id" => "state_dir", "status" => "failed",
              "detail" => "kept: data volumes not verifiably removed")
          )
          expect(File.exist?(File.join(home, ".syrus", "local", ".env"))).to be(true)
          expect(File.exist?(File.join(home, ".syrus", "local", "docker-compose.yml"))).to be(true)
          expect(err).to include("ENCRYPTION")
          expect(err).to include("partial uninstall")
          # Everything unrelated to the keys still goes.
          expect(File.exist?(File.join(home, ".syrus", "credentials"))).to be(false)
          expect(Dir.exist?(File.join(home, "Applications", "Syrus.app"))).to be(false)
          # The stream ends with an error event (code 3), never a false done.
          expect(events.map { |e| e["event"] }).not_to include("done")
          expect(events.last).to include("event" => "error", "code" => 3)

          # Second run: still refuses to delete the keys, still exits 3.
          out2, _err2, status2 = run_uninstall("--json", home: home, stub_dir: stub_dir)
          expect(status2.exitstatus).to eq(3)
          events2 = parse_events(out2)
          expect(events2).to include(
            hash_including("event" => "step", "id" => "state_dir", "status" => "failed")
          )
          expect(events2.last).to include("event" => "error", "code" => 3)
          expect(File.exist?(File.join(home, ".syrus", "local", ".env"))).to be(true)
        end
      end
    end

    it "reports a stopped daemon as unavailable and partial instead of claiming success" do
      Dir.mktmpdir do |stub_dir|
        Dir.mktmpdir do |home|
          write_uname_stub(stub_dir)
          write_docker_stub(stub_dir, daemon_up: false)
          populate_home(home)

          out, _err, status = run_uninstall("--json", home: home, stub_dir: stub_dir)
          expect(status.exitstatus).to eq(3)
          events = parse_events(out)
          expect(events).to include(
            hash_including("event" => "step", "id" => "docker_images", "status" => "skipped")
          )
          expect(events.last).to include("event" => "error", "code" => 3)
          # `docker info` was probed, but nothing destructive was attempted,
          # and the encryption keys stayed put.
          expect(stub_calls(stub_dir).grep(/\A(rm|rmi|volume|compose|ps) /)).to be_empty
          expect(File.exist?(File.join(home, ".syrus", "local", ".env"))).to be(true)
        end
      end
    end

    it "reports leftover volumes honestly — failed step, kept keys, exit 3 — when removal doesn't take" do
      Dir.mktmpdir do |stub_dir|
        Dir.mktmpdir do |home|
          write_uname_stub(stub_dir)
          write_docker_stub(stub_dir, stuck_volumes: true)
          populate_home(home)

          out, _err, status = run_uninstall("--json", home: home, stub_dir: stub_dir)
          expect(status.exitstatus).to eq(3)
          events = parse_events(out)
          down_step = events.find { |e| e["event"] == "step" && e["id"] == "docker_down" && e["status"] == "failed" }
          expect(down_step).not_to be_nil, "docker_down must be reported failed, not ok"
          expect(down_step["detail"]).to include("leftovers:")
          expect(down_step["detail"]).to include("syrus_syrus-data")
          # The keys-preservation gate rides on the verification result.
          expect(events).to include(
            hash_including("event" => "step", "id" => "state_dir", "status" => "failed",
              "detail" => "kept: data volumes not verifiably removed")
          )
          expect(File.exist?(File.join(home, ".syrus", "local", ".env"))).to be(true)
          expect(events.map { |e| e["event"] }).not_to include("done")
          expect(events.last).to include("event" => "error", "code" => 3)
        end
      end
    end

    it "logs refused image removals as left in place — never counted as removed, never forced" do
      Dir.mktmpdir do |stub_dir|
        Dir.mktmpdir do |home|
          write_uname_stub(stub_dir)
          write_docker_stub(stub_dir, rmi_fails: true)
          populate_home(home)

          out, _err, status = run_uninstall("--json", home: home, stub_dir: stub_dir)
          # A polite rmi refusal (image still referenced) is by design, not partial.
          expect(status.exitstatus).to eq(0)
          events = parse_events(out)
          images_step = events.find { |e| e["event"] == "step" && e["id"] == "docker_images" && e["status"] == "ok" }
          expect(images_step).not_to be_nil
          expect(images_step["detail"]).to eq("0 removed, 3 left in place")
          expect(events).to include(
            hash_including("event" => "log", "stream" => "docker",
              "line" => "left image ghcr.io/tkadauke/syrus-backend:0.1.2 in place (still referenced, or removal failed)")
          )
          # No -f fallback after the refusal.
          expect(stub_calls(stub_dir).grep(/\Armi -f/)).to be_empty
        end
      end
    end

    it "removes a validated --app-path bundle in addition to the default one" do
      Dir.mktmpdir do |stub_dir|
        Dir.mktmpdir do |home|
          write_uname_stub(stub_dir)
          write_docker_stub(stub_dir)
          populate_home(home)
          custom = File.join(home, "Applications", "Work", "Syrus.app")
          FileUtils.mkdir_p(File.join(custom, "Contents"))

          out, _err, status = run_uninstall("--json", "--app-path=#{custom}", home: home, stub_dir: stub_dir)
          expect(status.exitstatus).to eq(0)
          events = parse_events(out)
          expect(events).to include(hash_including("event" => "step", "id" => "desktop_app", "status" => "ok"))
          expect(events).to include(hash_including("event" => "step", "id" => "desktop_app_custom", "status" => "ok"))
          expect(Dir.exist?(custom)).to be(false)
          # The hardcoded per-user bundle is still removed alongside.
          expect(Dir.exist?(File.join(home, "Applications", "Syrus.app"))).to be(false)
        end
      end
    end

    it "treats --app-path pointing at the default bundle as already covered" do
      Dir.mktmpdir do |stub_dir|
        Dir.mktmpdir do |home|
          write_uname_stub(stub_dir)
          write_docker_stub(stub_dir)
          populate_home(home)
          default_app = File.join(home, "Applications", "Syrus.app")

          out, _err, status = run_uninstall("--json", "--app-path=#{default_app}", home: home, stub_dir: stub_dir)
          expect(status.exitstatus).to eq(0)
          events = parse_events(out)
          expect(events).to include(hash_including("event" => "step", "id" => "desktop_app", "status" => "ok"))
          expect(events).to include(
            hash_including("event" => "step", "id" => "desktop_app_custom", "status" => "skipped",
              "detail" => "same as the default app path")
          )
          expect(Dir.exist?(default_app)).to be(false)
        end
      end
    end

    it "warns about and never removes an invalid --app-path (wrong leaf, relative, outside Applications, symlink escape)" do
      Dir.mktmpdir do |stub_dir|
        write_uname_stub(stub_dir)

        # Wrong leaf: exists, but is not .../Syrus.app.
        Dir.mktmpdir do |home|
          write_docker_stub(stub_dir)
          populate_home(home)
          evil = File.join(home, "Applications", "Evil.app")
          FileUtils.mkdir_p(evil)
          out, err, status = run_uninstall("--json", "--app-path=#{evil}", home: home, stub_dir: stub_dir)
          expect(status.exitstatus).to eq(0)
          expect(parse_events(out)).to include(
            hash_including("event" => "step", "id" => "desktop_app_custom", "status" => "skipped",
              "detail" => "invalid --app-path ignored")
          )
          expect(err).to include("invalid --app-path")
          expect(Dir.exist?(evil)).to be(true)
        end

        # Relative paths are rejected outright.
        Dir.mktmpdir do |home|
          write_docker_stub(stub_dir)
          populate_home(home)
          out, err, status = run_uninstall("--json", "--app-path=Applications/Syrus.app", home: home, stub_dir: stub_dir)
          expect(status.exitstatus).to eq(0)
          expect(parse_events(out)).to include(
            hash_including("event" => "step", "id" => "desktop_app_custom", "status" => "skipped",
              "detail" => "invalid --app-path ignored")
          )
          expect(err).to include("invalid --app-path")
        end

        # Right leaf, but outside /Applications and $HOME/Applications.
        Dir.mktmpdir do |home|
          write_docker_stub(stub_dir)
          populate_home(home)
          elsewhere = File.join(home, "Elsewhere", "Syrus.app")
          FileUtils.mkdir_p(elsewhere)
          out, _err, status = run_uninstall("--json", "--app-path=#{elsewhere}", home: home, stub_dir: stub_dir)
          expect(status.exitstatus).to eq(0)
          expect(parse_events(out)).to include(
            hash_including("event" => "step", "id" => "desktop_app_custom", "status" => "skipped",
              "detail" => "invalid --app-path ignored")
          )
          expect(Dir.exist?(elsewhere)).to be(true)
        end

        # A symlink inside Applications whose real path escapes it: the
        # containment check runs on the RESOLVED path, so nothing is removed.
        Dir.mktmpdir do |home|
          write_docker_stub(stub_dir)
          populate_home(home)
          secret = File.join(home, "secret-data")
          FileUtils.mkdir_p(secret)
          FileUtils.mkdir_p(File.join(home, "Applications", "Alt"))
          link = File.join(home, "Applications", "Alt", "Syrus.app")
          File.symlink(secret, link)
          out, _err, status = run_uninstall("--json", "--app-path=#{link}", home: home, stub_dir: stub_dir)
          expect(status.exitstatus).to eq(0)
          expect(parse_events(out)).to include(
            hash_including("event" => "step", "id" => "desktop_app_custom", "status" => "skipped",
              "detail" => "invalid --app-path ignored")
          )
          expect(File.symlink?(link)).to be(true)
          expect(Dir.exist?(secret)).to be(true)
        end
      end
    end

    it "falls back to a project-name-only compose down when the state dir has no compose file" do
      Dir.mktmpdir do |stub_dir|
        Dir.mktmpdir do |home|
          write_uname_stub(stub_dir)
          write_docker_stub(stub_dir)
          populate_home(home)
          File.delete(File.join(home, ".syrus", "local", "docker-compose.yml"))

          _out, _err, status = run_uninstall("--json", home: home, stub_dir: stub_dir)
          expect(status.exitstatus).to eq(0)
          down = stub_calls(stub_dir).grep(/\Acompose /).grep(/ down /)
          expect(down.first).to include("-p syrus down -v --remove-orphans")
          expect(down.first).not_to include("-f ")
        end
      end
    end

    it "never touches shared tools" do
      expect(script_text).to include("NOT touched: Docker Desktop / OrbStack / Colima, Homebrew, rbenv")
      %w[brew rbenv colima].each do |tool|
        expect(script_text.scan(/^\s*#{tool}\b/)).to be_empty, "uninstall.sh must not invoke #{tool}"
      end
    end
  end

  describe "uninstall.ps1 parity" do
    it "emits the same NDJSON event vocabulary and shared step ids" do
      ps_events = ps1.scan(/\bevent = "(\w+)"/).flatten.uniq.sort
      expect(ps_events).to eq(%w[done error log start step])
      sh_steps = script_text.scan(/^\s*emit_step (\w+)/).flatten +
                 script_text.scan(/^\s*remove_step (\w+)/).flatten
      ps_steps = ps1.scan(/(?:Emit-Step|Remove-PathStep) "(\w+)"/).flatten.uniq.sort
      expect(sh_steps.uniq.sort).to eq(
        %w[app_settings cli credentials desktop_app desktop_app_custom docker_down docker_images skill state_dir]
      )
      # Windows never removes an --app-path bundle (the NSIS uninstaller owns
      # the app there) but adds the HKCU PATH surgery and the RunOnce cleanup.
      expect(ps_steps).to eq(((sh_steps - %w[desktop_app_custom]) + %w[path_cleanup runonce]).uniq.sort)
    end

    it "offers the same flag surface and confirmation gate" do
      %w[--yes --keep-data --json --app-path --help].each do |flag|
        expect(script_text).to include(flag)
        expect(ps1).to include(flag)
      end
      expect(ps1).to include('Read-Host "Remove Syrus from this machine? [y/N]"')
      expect(ps1).to include("Not an interactive shell. Pass --yes (or --json) to confirm removal.")
      expect(script_text).to include("Not an interactive shell. Pass --yes (or --json) to confirm removal.")
      # --json implies --yes in both (a GUI does its own confirmation).
      expect(script_text).to include("JSON=1; ASSUME_YES=1")
      expect(ps1).to include('$script:Json = $true; $script:AssumeYes = $true')
    end

    it "accepts --app-path in both scripts — validated on macOS, parsed-and-ignored on Windows" do
      # sh validation contract: absolute, /Syrus.app leaf, resolved (symlinks
      # followed) under /Applications or $HOME/Applications; anything else is
      # ignored, never removed.
      expect(script_text).to include("--app-path=*)")
      expect(script_text).to include("/*/Syrus.app)")
      expect(script_text).to include("/Applications/*")
      expect(script_text).to include('"$home_apps"/*')
      # ps1 parses the flag so passing it is never a usage error, and ignores
      # it: the NSIS uninstaller owns app removal on Windows.
      expect(ps1).to include('"--app-path"')
      expect(ps1).to include('$arg.StartsWith("--app-path=")')
    end

    it "tears down the same docker inventory — by compose label, verified, exact-basename images" do
      [
        "-p", "syrus",
        "label=com.docker.compose.project=syrus",
        "syrus_syrus-data", "syrus_syrus-search",
        "--remove-orphans"
      ].each do |token|
        expect(script_text).to include(token), "uninstall.sh: missing #{token.inspect}"
        expect(ps1).to include(token), "uninstall.ps1: missing #{token.inspect}"
      end
      # Containers are enumerated by compose label (v1 syrus_web_1 and v2
      # syrus-web-1 both carry it) — never by hardcoded container names that
      # miss one naming scheme.
      %w[syrus-web-1 syrus-worker-1 syrus-setup-1].each do |name|
        expect(script_text).not_to include(name), "uninstall.sh: hardcoded container name #{name}"
        expect(ps1).not_to include(name), "uninstall.ps1: hardcoded container name #{name}"
      end
      # Image matching is by exact repository basename (the documented
      # imageCleanup.ts semantics): a suffix glob would eat my-syrus-backend.
      expect(script_text).to include("syrus-backend|syrus-local)")
      expect(ps1).to include('-ne "syrus-backend"')
      expect(ps1).to include('-ne "syrus-local"')
      expect(script_text).not_to include("*syrus-backend")
      expect(ps1).not_to include("*syrus-backend")
      # rmi is never forced: -f untags every tag sharing the image ID.
      expect(script_text).not_to include("rmi -f")
      expect(ps1).not_to include('"rmi", "-f"')
    end

    it "exits 3 on partial teardown in both scripts, gated on verified volume removal" do
      expect(script_text).to include("exit 3")
      expect(ps1).to include("exit 3")
      # Both scripts delete the encryption keys only once the data volumes
      # are verifiably gone, and report the kept state dir as a failed step.
      expect(script_text).to include("volumes_verified_gone")
      expect(ps1).to include("VolumesVerifiedGone")
      expect(script_text).to include('emit_step state_dir failed "kept: data volumes not verifiably removed"')
      expect(ps1).to include('Emit-Step "state_dir" "failed" "kept: data volumes not verifiably removed"')
      # Partial runs end with an error event (code 3) instead of done.
      expect(script_text).to include('\"event\":\"error\",\"code\":3')
      expect(ps1).to include('event = "error"; code = 3')
      # File removals are verified too — a silently failed removal must not
      # report ok (Remove-Item -ErrorAction SilentlyContinue swallows errors).
      expect(script_text).to include("could not remove")
      expect(ps1).to include("could not remove")
      expect(ps1).to include("Add-Partial")
    end

    it "removes the Windows-only artifacts the desktop app creates" do
      expect(ps1).to include('Join-Path $localAppData "Syrus\bin"')
      expect(ps1).to include('"syrus.exe"')
      expect(ps1).to include('"syrus.exe.old"')
      expect(ps1).to include('.claude\skills\syrus')
      expect(ps1).to include("SyrusResumeSetup")
      expect(ps1).to include('Programs\syrus-desktop')
      # NSIS uninstaller runs silently and LAST (it can take the console's
      # context down with it).
      expect(ps1).to include('"Uninstall*.exe"')
      expect(ps1).to include('-ArgumentList "/S"')
      expect(ps1.index('-ArgumentList "/S"')).to be > ps1.index("SyrusResumeSetup")
    end

    it "reverses the desktop app's HKCU PATH surgery, kind-preserving, with a settings broadcast" do
      # Mirror of addToWindowsUserPath (desktop/electron/main.ts): raw value
      # read with expansion disabled, same value kind written back, and a
      # WM_SETTINGCHANGE broadcast; setx would truncate and rewrite the kind.
      expect(ps1).to include("DoNotExpandEnvironmentNames")
      expect(ps1).to include("GetValueKind")
      expect(ps1).to include("SendMessageTimeout")
      expect(ps1).not_to match(/^\s*setx\b/)
    end

    describe "PowerShell 5.1 safety" do
      it "keeps stdout protocol-only: console writers plus compact JSON, never host writers" do
        expect(ps1).to include("[Console]::Out.WriteLine")
        expect(ps1).to include("[Console]::Error.WriteLine")
        expect(ps1).to include("ConvertTo-Json -Compress")
        expect(ps1).not_to include("Write-Host")
      end

      it "sets a UTF-8 console encoding before emitting protocol output" do
        expect(ps1).to include("[Console]::OutputEncoding")
      end

      it "stays pure ASCII because PS 5.1 parses BOM-less files with the ANSI codepage" do
        non_ascii = ps1.bytes.reject { |b| b < 128 }
        expect(non_ascii).to be_empty
      end
    end
  end
end
