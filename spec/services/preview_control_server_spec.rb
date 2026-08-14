require "rails_helper"
require "rack/mock"

RSpec.describe PreviewControlServer do
  let(:server) { described_class.new }
  let(:job) { Factories.job }
  let(:workspace_path) { Dir.mktmpdir }

  after { FileUtils.rm_rf(workspace_path) }

  def create_env(**attrs)
    PreviewEnvironment.create!({ job: job, workspace_path: workspace_path, state: "starting" }.merge(attrs))
  end

  def call(path)
    server.call(Rack::MockRequest.env_for(path))
  end

  def json_body(response)
    JSON.parse(response[2].first)
  end

  it "returns tailed logs for a known environment" do
    FileUtils.mkdir_p(File.join(workspace_path, "log"))
    File.write(File.join(workspace_path, "log", "development.log"), "first\nsecond\nthird\n")
    env = create_env

    response = call("/environments/#{env.id}/logs?lines=2")

    expect(response[0]).to eq(200)
    expect(json_body(response)["logs"]).to include(
      a_hash_including("path" => "log/development.log", "content" => "second\nthird", "missing" => false)
    )
  end

  it "defaults the line count when no lines param is given" do
    FileUtils.mkdir_p(File.join(workspace_path, "log"))
    File.write(File.join(workspace_path, "log", "development.log"), "only line\n")
    env = create_env

    response = call("/environments/#{env.id}/logs")

    expect(response[0]).to eq(200)
    expect(json_body(response)["logs"]).to include(
      a_hash_including("path" => "log/development.log", "content" => "only line")
    )
  end

  it "returns 404 for an unknown environment id" do
    response = call("/environments/999999/logs")

    expect(response[0]).to eq(404)
    expect(json_body(response)).to eq("error" => "not_found")
  end

  it "returns 404 for paths that don't match the logs route" do
    response = call("/nope")

    expect(response[0]).to eq(404)
  end
end
