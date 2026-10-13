require "rails_helper"

RSpec.describe "Vite build config" do
  let(:config) { Rails.root.join("vite.config.ts").read }

  it "keeps the Rails SPA entrypoint logical while allowing hashed chunks" do
    expect(config).to include('entryFileNames: "spa.js"')
    expect(config).to include('chunkFileNames: "spa-[name]-[hash].js"')
    expect(config).not_to include("codeSplitting: false")
  end

  it "splits heavyweight dependencies out of the startup bundle" do
    expect(config).to include("manualChunks(id)")
    expect(config).to include('"vendor-react"')
    expect(config).to include('"vendor-query"')
    expect(config).to include('"vendor-visualization"')
  end
end
