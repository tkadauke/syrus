require "rails_helper"
require "yaml"

RSpec.describe "Local Backups deployment templates" do
  let(:directory) { Rails.root.join("config/deploy/kubernetes") }

  it "defaults k3s to one hardened backup owner with an RWO claim" do
    claim, owner = YAML.load_stream(directory.join("local-backups-rwo.yaml").read)
    expect(claim.dig("spec", "accessModes")).to eq(["ReadWriteOnce"])
    expect(owner.dig("spec", "replicas")).to eq(1)
    expect(owner.dig("spec", "strategy", "type")).to eq("Recreate")
    expect(owner.dig("spec", "template", "spec", "securityContext")).to include("runAsUser" => 1000, "fsGroup" => 1000)
    expect(owner.dig("spec", "template", "spec", "containers", 0, "securityContext"))
      .to include("allowPrivilegeEscalation" => false, "capabilities" => { "drop" => ["ALL"] })
  end

  it "retains an explicit RWX topology using the dedicated claim" do
    claim, pod = YAML.load_stream(directory.join("local-backups-rwx.yaml").read)
    expect(claim.dig("spec", "accessModes")).to eq(["ReadWriteMany"])
    expect(pod.dig("spec", "volumes", 0, "persistentVolumeClaim", "claimName")).to eq("syrus-backups")
  end

  it "defines Helm inputs for capacity, storage class, reserves, security, and bounded operations" do
    values = YAML.safe_load(directory.join("local-backups-values.yaml").read).fetch("localBackups")
    expect(values.fetch("persistence").keys).to contain_exactly("capacity", "storageClass", "accessMode")
    expect(values.fetch("construction")).to include("objectConcurrency" => 4, "minimumFreePercent" => 10)
    expect(values.fetch("securityContext")).to include("runAsUser" => 1000, "allowPrivilegeEscalation" => false)
    expect(values.fetch("authenticatedOperations").values).to all(eq(true))
  end

  it "gives the bare-metal backup identity exclusive ownership" do
    entry = Rails.root.join("config/deploy/systemd/syrus-backups.tmpfiles").read.strip.split
    expect(entry).to eq(%w[d /var/lib/syrus/backups 0700 syrus-backup syrus-backup -])
  end
end
