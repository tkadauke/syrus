require "rails_helper"

RSpec.describe "roadmap tenancy boundary" do
  it "records the OSS isolation mechanism and commercial tenancy split" do
    body = Rails.root.join("ROADMAP.md").read.squish

    expect(body).to include("### OSS isolation, commercial tenancy")
    expect(body).to include("`Execution::Backend` seam and its conformance kit")
    expect(body).to include("containers, user namespaces, seccomp, dropped capabilities")
    expect(body).to include("Kubernetes `NetworkPolicy`")
    expect(body).to include("gVisor support")
    expect(body).to include("Tenant lifecycle, quota and billing, fleet orchestration")
    expect(body).to include("per-tenant provisioning are commercial, closed-source scope")
    expect(body).to include("They will not have corresponding implementation Jobs in this repository")
    expect(body).to include("[DOC-33 §4](/design_docs/33)")
  end
end
