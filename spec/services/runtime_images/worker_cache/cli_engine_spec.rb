require "rails_helper"

RSpec.describe RuntimeImages::WorkerCache::CliEngine do
  subject(:engine) { described_class.new(binary: "docker") }

  def capture(success: true, timed_out: false, stdout: "", stderr: "")
    result = instance_double(ProcessRunner::Result, success?: success, timed_out?: timed_out)
    double(result: result, stdout: stdout, stderr: stderr)
  end

  def stub_runner(response)
    runner = instance_double(ProcessRunner, capture: response)
    allow(ProcessRunner).to receive(:new) { |**opts| (@opts ||= []) << opts; runner }
  end

  it "reads proven digests from RepoDigests" do
    stub_runner(capture(stdout: '["host/repo@sha256:abc"]'))
    expect(engine.digests("host/repo@sha256:abc")).to eq(["sha256:abc"])
  end

  it "reports no digests for an absent image or unparsable output" do
    stub_runner(capture(success: false))
    expect(engine.digests("x")).to eq([])
    stub_runner(capture(stdout: "nope"))
    expect(engine.digests("x")).to eq([])
  end

  it "raises EngineTimeout when a pull times out" do
    stub_runner(capture(success: false, timed_out: true))
    expect { engine.pull("host/r@sha256:a", timeout: 1) }.to raise_error(RuntimeImages::WorkerCache::EngineTimeout)
  end

  it "raises EngineError with the engine's last line when a pull fails" do
    stub_runner(capture(success: false, stderr: "x\nunauthorized\n"))
    expect { engine.pull("host/r@sha256:a", timeout: 1) }.to raise_error(RuntimeImages::WorkerCache::EngineError, /unauthorized/)
  end

  it "scopes the pull token to a throwaway docker config" do
    stub_runner(capture)
    engine.pull("reg.example/r@sha256:a", timeout: 5, auth: { token: "tok" })
    expect(@opts.last[:env]).to include("DOCKER_CONFIG")
    expect(@opts.last[:network]).to eq("prepare")
  end

  it "exports through `docker save` and parses the OCI archive" do
    stub_runner(capture)
    expect(RuntimeImages::WorkerCache::OciArchive).to receive(:read).with(a_string_ending_with("image.tar"), platform: "linux/amd64")
      .and_return(manifest: "{}", blobs: {})

    expect(engine.export_oci("local:tag", platform: "linux/amd64")).to eq(manifest: "{}", blobs: {})
    expect(@opts.last[:command]).to include("save", "--output", "local:tag")
  end

  it "raises EngineError when the engine cannot save the image" do
    stub_runner(capture(success: false, stderr: "no such image\n"))
    expect { engine.export_oci("local:tag", platform: "linux/amd64") }
      .to raise_error(RuntimeImages::WorkerCache::EngineError, /no such image/)
  end
end
