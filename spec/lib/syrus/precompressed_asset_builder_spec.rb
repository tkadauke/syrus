require "rails_helper"

RSpec.describe Syrus::PrecompressedAssetBuilder do
  let(:output_path) { Pathname.new(Dir.mktmpdir("precompressed-assets")) }
  let(:builder) { described_class.new(output_path: output_path) }

  after { FileUtils.rm_rf(output_path) }

  it "runs Brotli probes and compression through ProcessRunner" do
    asset = output_path.join("app.js")
    asset.write("console.log('hello')")
    success = instance_double(ProcessRunner::CaptureResult, success?: true, stderr: "")
    runner = instance_double(ProcessRunner, capture: success)
    allow(ProcessRunner).to receive(:new).and_return(runner)

    written = builder.call

    expect(written).to include(Pathname.new("#{asset}.br"), Pathname.new("#{asset}.gz"))
    expect(ProcessRunner).to have_received(:new).with(hash_including(
      command: [ "brotli", "--version" ], kind: "generate", network: "grader"
    ))
    expect(ProcessRunner).to have_received(:new).with(hash_including(
      command: [ "brotli", "--quality=11", "--force", "--output=#{asset}.br", asset.to_s ],
      kind: "generate"
    ))
  end

  it "preserves the compressor failure message" do
    asset = output_path.join("app.js")
    asset.write("console.log('hello')")
    probe = instance_double(ProcessRunner::CaptureResult, success?: true, stderr: "")
    failure = instance_double(ProcessRunner::CaptureResult, success?: false, stderr: "compression broke")
    allow(ProcessRunner).to receive(:new).and_return(
      instance_double(ProcessRunner, capture: probe),
      instance_double(ProcessRunner, capture: failure)
    )

    expect { builder.call }.to raise_error("brotli failed for #{asset}: compression broke")
  end
end
