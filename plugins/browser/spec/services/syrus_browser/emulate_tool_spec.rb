require "rails_helper"

RSpec.describe SyrusBrowser::EmulateTool do
  let(:run) { instance_double(Run, id: 42) }
  let(:session) { instance_double(SyrusBrowser::Session, call_tool: nil, close: nil) }
  let(:ctx) { { run_id: 42 } }
  let(:state) { SyrusBrowser::EmulationPresets::IPHONE_15_PRO }

  def upstream_response(state_hash)
    marker = "#{described_class::STATE_MARKER}#{Base64.strict_encode64(JSON.generate(state_hash))}"
    { "result" => { "content" => [ { "type" => "text", "text" => "### Result\n\"#{marker}\"" } ] } }
  end

  def sent_patch
    code = nil
    expect(session).to have_received(:call_tool) { |name:, arguments:| code = arguments["code"]; expect(name).to eq("browser_run_code_unsafe") }
    JSON.parse(code[/const patch = (.*);\n/, 1])
  end

  before do
    allow(Mcp::Tools).to receive(:run_from_context).with(ctx).and_return(run)
    SyrusBrowser::SessionRegistry.session_factory = ->(_run_id) { session }
    allow(session).to receive(:call_tool).and_return(upstream_response(JSON.parse(JSON.generate(state))))
  end

  after { SyrusBrowser::SessionRegistry.reset! }

  it "declares the browser_emulate tool name with no required fields" do
    expect(described_class.tool_name).to eq("browser_emulate")
    expect(described_class.input_schema_value.to_h[:required]).to be_blank
  end

  describe "presets" do
    it "resolves iphone-15-pro to the full device profile" do
      response = described_class.call(preset: "iphone-15-pro", server_context: ctx)

      expect(response).not_to be_error
      patch = sent_patch
      expect(patch["viewport"]).to eq("width" => 393, "height" => 852)
      expect(patch["device_scale_factor"]).to eq(3)
      expect(patch).to include("is_mobile" => true, "has_touch" => true)
      expect(patch["user_agent"]).to include("iPhone")
      expect(patch["safe_area_insets"]).to eq("top" => 59, "right" => 0, "bottom" => 34, "left" => 0)
      expect(response.content.first[:text]).to include("viewport 393x852 @3x", "safe-area top=59")
    end

    it "desktop resets every emulated field including insets" do
      described_class.call(preset: "desktop", server_context: ctx)

      patch = sent_patch
      expect(patch["viewport"]).to eq("width" => 1280, "height" => 720)
      expect(patch).to include("device_scale_factor" => 1, "is_mobile" => false, "has_touch" => false, "user_agent" => "")
      expect(patch["safe_area_insets"]).to eq("top" => 0, "right" => 0, "bottom" => 0, "left" => 0)
      expect(patch["color_scheme"]).to be_nil
      expect(patch["reduced_motion"]).to be_nil
    end

    it "rejects an unknown preset without touching the browser" do
      response = described_class.call(preset: "nokia-3310", server_context: ctx)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("unknown preset", "iphone-15-pro")
      expect(session).not_to have_received(:call_tool)
    end
  end

  describe "explicit fields" do
    it "override preset values, merging nested objects key by key" do
      described_class.call(
        preset: "iphone-15-pro", viewport: { width: 430 }, safe_area_insets: { top: 47 },
        has_touch: false, color_scheme: "dark", reduced_motion: true, server_context: ctx
      )

      patch = sent_patch
      expect(patch["viewport"]).to eq("width" => 430, "height" => 852)
      expect(patch["safe_area_insets"]).to eq("top" => 47, "right" => 0, "bottom" => 34, "left" => 0)
      expect(patch["has_touch"]).to be(false)
      expect(patch).to include("color_scheme" => "dark", "reduced_motion" => true, "is_mobile" => true)
    end

    it "sends only the specified fields when no preset is given" do
      described_class.call(color_scheme: "dark", server_context: ctx)

      expect(sent_patch).to eq("color_scheme" => "dark")
    end
  end

  describe "validation" do
    {
      "no fields" => {},
      "bad color scheme" => { color_scheme: "sepia" },
      "zero width" => { viewport: { width: 0, height: 800 } },
      "huge height" => { viewport: { width: 400, height: 100_000 } },
      "fractional width" => { viewport: { width: 400.5 } },
      "empty viewport" => { viewport: {} },
      "negative inset" => { safe_area_insets: { top: -1 } },
      "non-numeric inset" => { safe_area_insets: { top: "59" } },
      "scale factor too big" => { device_scale_factor: 50 },
      "non-boolean touch" => { has_touch: "yes" },
      "non-string user agent" => { user_agent: 5 }
    }.each do |label, args|
      it "rejects #{label}" do
        response = described_class.call(**args, server_context: ctx)

        expect(response).to be_error
        expect(session).not_to have_received(:call_tool)
      end
    end
  end

  describe "upstream failures" do
    it "surfaces an unsupported-browser error from the upstream tool" do
      allow(session).to receive(:call_tool).and_return(
        "result" => { "isError" => true, "content" => [ { "type" => "text", "text" => "CDP emulation is unsupported by this browser" } ] }
      )

      response = described_class.call(preset: "desktop", server_context: ctx)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("unsupported")
    end

    it "errors instead of reporting success when the browser never confirms the state" do
      allow(session).to receive(:call_tool).and_return("result" => { "content" => [ { "type" => "text", "text" => "ok" } ] })

      expect(described_class.call(preset: "desktop", server_context: ctx)).to be_error
    end
  end

  it "re-reads the page viewport so a prior browser_resize is kept by media-only emulation" do
    described_class.call(color_scheme: "dark", server_context: ctx)

    expect(sent_patch).not_to have_key("viewport")
    expect(session).to have_received(:call_tool) do |name:, arguments:|
      expect(arguments["code"]).to include("page.viewportSize()")
    end
  end

  it "embeds the CDP safe-area command in the generated script" do
    described_class.call(preset: "iphone-15-pro", server_context: ctx)

    expect(session).to have_received(:call_tool) do |name:, arguments:|
      expect(name).to eq("browser_run_code_unsafe")
      expect(arguments["code"]).to include("Emulation.setSafeAreaInsetsOverride", "newCDPSession")
    end
  end
end
