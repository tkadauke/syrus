require "rails_helper"

RSpec.describe "Syrus Dev SPA loader boundary" do
  it "reads loader diagnostics only through the frontend host SDK" do
    source = Rails.root.join("plugins/syrus_dev/app/frontend/routes/AdminSpaLoader.tsx").read

    expect(source).to include('from "@app/pluginSdk"')
    expect(source).not_to include("chunkWarmup")
    expect(source).not_to include("startupDiagnostics")
    expect(source).not_to include("staleChunkRecovery")
  end
end
