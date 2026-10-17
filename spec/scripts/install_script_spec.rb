require "spec_helper"

RSpec.describe "install.sh" do
  let(:script) { File.read(File.expand_path("../../install.sh", __dir__), encoding: "UTF-8") }

  it "prints compact first-run next steps after Docker startup" do
    # ${port} is defaulted to 3000 right after it's read from .env.
    expect(script).to include('port="${port:-3000}"')
    expect(script).to include('info "Syrus is running at http://localhost:${port}"')
    expect(script).to include('info "Next steps:"')
    expect(script).to include('info "  1. Open http://localhost:${port} and create the first admin account."')
    expect(script).to include('info "  2. Complete /onboarding: GitHub credentials, agent, first repository."')
    expect(script).to include('info "  3. Logs: docker compose -p $PROJECT logs -f web worker   Stop: docker compose -p $PROJECT down"')
    expect(script).to include('info "  4. Read README.md or website docs for next steps."')
  end

  # The behavioral coverage for this guard lives in
  # spec/desktop/install_sh_gui_spec.rb, which runs the real script against a
  # stubbed docker and is :ci_only. These structural assertions keep the
  # contract in the fast local/grader loop too, where that file is excluded.
  describe "wrong-daemon guard" do
    it "aborts with exit 21 when the data volume belongs to another Docker context" do
      expect(script).to include("contexts_holding_volume")
      expect(script).to match(/die "data volume \(\$DATA_VOLUME\) belongs to another Docker context: \$other_contexts" 21/)
    end

    it "only aborts on a positive sighting, so a half-finished install stays recoverable" do
      # A missing volume alone is ambiguous (first install died after writing
      # .env, or a deliberate `down -v`). Absence of evidence must only warn.
      guard = script[/  # The mirror of that guard.*?\n  fi\n/m]
      expect(guard).not_to be_nil, "wrong-daemon guard block not found"
      expect(guard).to include('if [ -n "$other_contexts" ] && [ "$ALLOW_FRESH_DATA" != "1" ]; then')
      expect(guard).to include("starting empty")
    end

    it "documents --allow-fresh-data and exit 21 in the help header" do
      header = script[/\A(#.*\n)+/]
      expect(header).to include("--allow-fresh-data")
      expect(header).to include("21 the data volume belongs to a different")
    end

    it "treats --allow-fresh-data as docker-only, like the other GUI flags" do
      expect(script).to include('--allow-fresh-data)     ALLOW_FRESH_DATA=1 ;;')
      expect(script).to include('|| [ "$ALLOW_FRESH_DATA" = "1" ]; then')
    end
  end

  describe "pinned-image update safety" do
    it "resolves the state directory's image pin before exporting the Compose override" do
      resolution = script.index('ENV_IMAGE="$(sed -n')
      export = script.index('export SYRUS_IMAGE="$IMAGE"')

      expect(resolution).not_to be_nil
      expect(export).to be > resolution
      expect(script).to include('IMAGE="${IMAGE_OVERRIDE:-${PROCESS_IMAGE:-${ENV_IMAGE:-ghcr.io/tkadauke/syrus-backend:latest}}}"')
    end

    it "backs up a stopped data volume before a changed image can run db:prepare" do
      backup = script.index('emit_log backup "$backup_reason; backing up')
      stack_up = script.index('run_logged up compose up -d')

      expect(backup).not_to be_nil
      expect(stack_up).to be > backup
      expect(script.index('prior_web_container="$(compose ps -aq web')).to be < script.index('emit_step image_pull start')
      expect(script).to include("docker inspect --format '{{.Image}}'")
      expect(script).to include("docker image inspect --format '{{.Id}}'")
      expect(script).to include('backup_reason="existing data volume has no prior container metadata"')
      expect(script).to include('run_logged up compose stop')
      expect(script).to include('--mount "type=volume,src=$DATA_VOLUME,dst=/source,readonly"')
      expect(script).to match(/die "couldn't back up \$DATA_VOLUME; the new image was not started" 42/)
    end
  end
end
