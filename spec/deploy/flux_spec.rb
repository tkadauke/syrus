# frozen_string_literal: true

require_relative "deploy_helper"
require "stringio"

RSpec.describe Deploy::Flux do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:reporter) { Deploy::Reporter.new(out: out, err: err) }
  let(:controls) { Deploy::ControlStack.new(reporter: reporter) }
  let(:registries) { [ "ghcr.io/tkadauke/syrus", "ghcr.io/tkadauke/syrus-plugin-git-mirror" ] }

  def kustomization(suspend: false, images: [])
    { "kind" => "Kustomization", "metadata" => { "name" => "apps" },
      "spec" => { "suspend" => suspend, "images" => images } }
  end

  def build(resources, env: {})
    fake = DeploySpec::FakeKubectl.new(namespace: "flux-system", resources: resources)
    context = DeploySpec.context(
      kubectl: fake, flux_kubectl: fake, config: Deploy::Config.new(env: env),
      reporter: reporter, controls: controls
    )
    [ described_class.new(context), fake ]
  end

  describe "when there is no Flux in the cluster" do
    it "proceeds without suspending anything" do
      flux, fake = build({})

      flux.suspend!
      flux.pin_desired_images!(registries)
      flux.verify_desired_images!(registries)

      expect(fake.writes).to be_empty
      expect(out.string).to include("not found in 'flux-system' — proceeding without suspend")
    end
  end

  describe "suspending" do
    it "patches suspend, registers the resume, and leaves a watchdog behind" do
      flux, fake = build({ "kustomization apps" => kustomization })

      flux.configure_ttl!(4)
      flux.suspend!

      rbac = fake.writes.first[:manifest]
      expect(rbac.fetch("items").map { |item| item.fetch("kind") })
        .to eq(%w[ServiceAccount Role RoleBinding])
      expect(rbac.dig("items", 1, "rules", 0, "verbs")).to eq(%w[get patch])
      expect(fake.actions).to include("patch kustomization apps")
      expect(fake.actions.last).to start_with("apply Job syrus-flux-resume-")
      expect(controls.pending).to include("flux kustomization/apps suspension")
    end

    # An in-process handler does not run if the laptop sleeps, the terminal
    # closes, or the process is killed with -9. A suspension nobody lifts stops
    # a cluster reconciling indefinitely and nothing alerts on it.
    it "gives the watchdog a TTL covering the whole deploy budget" do
      flux, fake = build({ "kustomization apps" => kustomization })

      flux.configure_ttl!(4)
      flux.suspend!

      watchdog = fake.writes.last[:manifest]
      budget = Deploy::Config.new(env: {}).flux_suspend_budget_seconds(4)
      expect(watchdog.dig("spec", "activeDeadlineSeconds")).to be > budget
      expect(watchdog.dig("spec", "template", "spec", "containers", 0, "args", 0))
        .to include("sleep #{budget}", "suspend\":false")
    end

    it "warns when the operator's TTL is shorter than the deploy needs" do
      flux, _fake = build({ "kustomization apps" => kustomization }, env: { "FLUX_SUSPEND_TTL" => "60" })

      flux.configure_ttl!(4)

      expect(err.string).to include("FLUX_SUSPEND_TTL=60s is below the computed deploy budget")
    end

    # Resuming what this deploy did not suspend would silently undo a decision
    # the script knows nothing about.
    it "leaves an operator's own suspension in place, and does not resume it" do
      flux, fake = build({ "kustomization apps" => kustomization(suspend: true) })

      flux.suspend!
      flux.resume!

      expect(fake.writes).to be_empty
      expect(out.string).to include("was already suspended — leaving it suspended")
    end
  end

  describe "pinning the desired images" do
    # Updating desired state before live state is what makes resuming a no-op
    # instead of a second rollout: Flux comes back, compares, and finds the pod
    # template it would have written already running.
    it "replaces our overrides and keeps everybody else's" do
      existing = [ { "name" => "ghcr.io/tkadauke/syrus", "newTag" => "old" },
                   { "name" => "ghcr.io/other/thing", "newTag" => "v1" } ]
      flux, fake = build({ "kustomization apps" => kustomization(images: existing) })

      flux.pin_desired_images!(registries)

      images = fake.writes.last[:patch].dig("spec", "images")
      expect(images).to include({ "name" => "ghcr.io/other/thing", "newTag" => "v1" })
      expect(images).to include({ "name" => "ghcr.io/tkadauke/syrus", "newTag" => "abc1234" })
      expect(images).to include({ "name" => "ghcr.io/tkadauke/syrus-plugin-git-mirror", "newTag" => "abc1234" })
      expect(images.count { |image| image["name"] == "ghcr.io/tkadauke/syrus" }).to eq(1)
    end

    it "uses the field manager Flux's own client-side apply uses" do
      flux, fake = build({ "kustomization apps" => kustomization })

      flux.pin_desired_images!(registries)

      expect(fake.writes.last[:field_manager]).to eq("flux-client-side-apply")
    end

    # A failed deploy must leave the desired state naming the revision that is
    # actually running, not the one that did not finish rolling out.
    it "restores the previous overrides when the deploy unwinds" do
      existing = [ { "name" => "ghcr.io/tkadauke/syrus", "newTag" => "previous" } ]
      flux, fake = build({ "kustomization apps" => kustomization(images: existing) })

      flux.pin_desired_images!(registries)
      controls.unwind

      expect(fake.writes.last[:patch].dig("spec", "images")).to eq(existing)
    end

    # On the happy path the pin is the state we want to keep, so the restore
    # has to be retired or the stack would undo a good deploy.
    it "keeps the new overrides once the rollout is verified" do
      flux, fake = build({ "kustomization apps" => kustomization })

      flux.pin_desired_images!(registries)
      flux.accept_desired_images!
      writes_before = fake.writes.length
      controls.unwind

      expect(fake.writes.length).to eq(writes_before)
    end
  end

  describe "resuming" do
    it "patches suspend off and asks for an immediate reconcile" do
      flux, fake = build({ "kustomization apps" => kustomization })

      flux.configure_ttl!(1)
      flux.suspend!
      flux.resume!

      expect(fake.actions.last).to start_with("annotate kustomization apps reconcile.fluxcd.io/requestedAt=")
      expect(controls.pending).not_to include("flux kustomization/apps suspension")
    end
  end

  describe "verifying the desired images" do
    it "accepts overrides that name this revision" do
      images = registries.map { |name| { "name" => name, "newTag" => "abc1234" } }
      flux, _fake = build({ "kustomization apps" => kustomization(images: images) })

      expect { flux.verify_desired_images!(registries) }.not_to raise_error
    end

    # Without this, a pin that silently failed leaves Flux's next reconcile to
    # roll the cluster back to the previous image minutes after the deploy
    # reported success.
    it "fails when an override did not land, naming the image" do
      images = [ { "name" => "ghcr.io/tkadauke/syrus", "newTag" => "abc1234" } ]
      flux, _fake = build({ "kustomization apps" => kustomization(images: images) })

      expect { flux.verify_desired_images!(registries) }
        .to raise_error(Deploy::Failure, /do not include expected revision tags/) { |error|
          expect(error.detail).to include("syrus-plugin-git-mirror:abc1234")
        }
    end

    # The pin was recorded, not applied, so the live overrides still name the
    # previously deployed revision. That is the dry run behaving correctly.
    it "is skipped in a dry run" do
      fake = DeploySpec::FakeKubectl.new(namespace: "flux-system",
        resources: { "kustomization apps" => kustomization })
      context = DeploySpec.context(kubectl: fake, flux_kubectl: fake, reporter: reporter,
        controls: controls, dry_run: true)

      expect { described_class.new(context).verify_desired_images!(registries) }.not_to raise_error
    end
  end
end
