require "rails_helper"

RSpec.describe Coworkers::EnvironmentSource do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Env", handle: "env-src", workspace_repo: repository.remote_url)
  end
  let(:root) { Pathname.new(Dir.mktmpdir) }
  let(:workspace) do
    chat = ChatSession.create!(user: owner)
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    allow(Syrus::Host::ChatWorkspaces).to receive(:repo_path_for).and_return(root)
    Coworkers::Workspace.new(chat)
  end
  let(:source) { described_class.new(coworker, workspace) }

  before { Feature.create!(slug: "coworker_custom_environments", category: "Labs", name: "x", enabled: true, experimental: true) }
  before { allow(AppSetting).to receive(:beta_mode_enabled?).and_return(true) }
  after { FileUtils.remove_entry(root) }

  it "refuses to act while the feature is disabled" do
    Feature.find_by!(slug: "coworker_custom_environments").update!(enabled: false)
    expect { source.seed! }.to raise_error(described_class::Disabled)
    expect { source.snapshot! }.to raise_error(described_class::Disabled)
  end

  it "seeds missing files without overwriting existing ones" do
    workspace.write("environment/smoke-test", "#!/bin/sh\ntrue\n")
    expect(source.seed!).to contain_exactly("environment/Dockerfile", "environment/environment.yml")
    expect(root.join("environment/smoke-test").read).to eq("#!/bin/sh\ntrue\n")
    expect(source.seed!).to be_empty
    expect(coworker.reload.environment.state).to eq("draft")
    expect(source.validate).to be_empty
  end

  it "captures an immutable revision and dedupes unchanged source" do
    source.seed!
    first = source.snapshot!
    expect(first).to have_attributes(created: true)
    expect(first.revision.number).to eq(1)
    expect(first.revision.source_manifest["files"].keys).to match_array(described_class::REQUIRED_FILES)
    expect(source.snapshot!).to have_attributes(created: false, revision: first.revision)

    workspace.edit("environment/Dockerfile", "# Coworker additions follow.", "RUN echo hi")
    second = source.snapshot!
    expect(second.revision.number).to eq(2)
    expect(second.revision.source_digest).not_to eq(first.revision.source_digest)
    expect(first.revision.reload.source_manifest["files"]["environment/Dockerfile"]["content"]).not_to include("RUN echo")
  end

  it "rejects a Dockerfile that does not descend from the Syrus base" do
    source.seed!
    workspace.write("environment/Dockerfile", "FROM ubuntu:24.04\n")
    expect(source.validate).to include(a_string_matching(/final stage must descend/))
    expect { source.snapshot! }.to raise_error(described_class::Invalid)
  end

  it "ignores FROM lines inside heredoc bodies" do
    source.seed!
    workspace.write("environment/Dockerfile", "FROM ubuntu:24.04\nRUN <<EOF\nFROM ${SYRUS_COWORKER_BASE}\nEOF\n")
    expect(source.validate).to include(a_string_matching(/final stage must descend/))
  end

  it "does not read << inside quoted text as a heredoc that hides a later FROM" do
    source.seed!
    workspace.write("environment/Dockerfile",
                    "ARG SYRUS_COWORKER_BASE\nFROM ${SYRUS_COWORKER_BASE}\nRUN echo \"<<CMD\"\nFROM ubuntu:24.04\nCMD echo hello\n")
    expect(source.validate).to include(a_string_matching(/final stage must descend/))
  end

  it "rejects escaped < that BuildKit would not read as a heredoc" do
    source.seed!
    workspace.write("environment/Dockerfile",
                    "ARG SYRUS_COWORKER_BASE\nFROM ${SYRUS_COWORKER_BASE}\nRUN touch CMD && echo \\<<CMD\nFROM ubuntu:24.04\nCMD echo hello\n")
    expect(source.validate).to include(a_string_matching(/must not escape '<'/))
  end

  it "rejects a non-default escape parser directive that would change continuation" do
    source.seed!
    workspace.write("environment/Dockerfile",
                    "# escape=`\nARG SYRUS_COWORKER_BASE\nFROM ${SYRUS_COWORKER_BASE}\nLABEL marker=\\\nFROM ubuntu:24.04\n")
    expect(source.validate).to include(a_string_matching(/escape parser directive/))
  end

  it "still recognizes quoted heredoc tags" do
    source.seed!
    workspace.write("environment/Dockerfile",
                    "FROM ubuntu:24.04\nRUN <<\"EOF\"\nFROM ${SYRUS_COWORKER_BASE}\nEOF\n")
    expect(source.validate).to include(a_string_matching(/final stage must descend/))
  end

  it "accepts multi-stage builds whose final stage descends from the base" do
    source.seed!
    workspace.write("environment/Dockerfile",
                    "ARG SYRUS_COWORKER_BASE\nFROM ubuntu AS tools\nFROM ${SYRUS_COWORKER_BASE} AS base\nFROM base\nRUN true\n")
    expect(source.validate).to be_empty
  end

  it "rejects unsafe manifest shapes" do
    source.seed!
    workspace.write("environment/environment.yml",
                    "schema_version: 1\nnetwork_classes: [\"Bad Class\"]\nsmoke_test: ../x\nprivileged: true\n")
    errors = source.validate
    expect(errors).to include(a_string_matching(/unsupported keys: privileged/),
                              a_string_matching(/network_classes/), a_string_matching(/smoke_test/))
  end

  it "reports missing files and invalid YAML" do
    expect(source.validate).to include("environment/Dockerfile is missing")
    source.seed!
    workspace.write("environment/environment.yml", "a: [")
    expect(source.validate).to include(a_string_matching(/not valid YAML/))
  end

  it "rejects symlinks inside the source tree" do
    source.seed!
    outside = Pathname.new(Dir.mktmpdir)
    File.write(outside.join("secret"), "s")
    File.symlink(outside.join("secret"), root.join("environment/leak"))
    expect(source.validate).to include(a_string_matching(/symbolic links/))
    expect { source.snapshot! }.to raise_error(described_class::Invalid)
  ensure
    FileUtils.remove_entry(outside) if outside
  end

  it "rejects an environment directory that is itself a symlink" do
    outside = Pathname.new(Dir.mktmpdir)
    File.symlink(outside, root.join("environment"))
    expect(source.validate).to include(a_string_matching(/symbolic links|escapes/))
    expect { source.seed! }.to raise_error(described_class::Invalid)
  ensure
    FileUtils.remove_entry(outside) if outside
  end

  it "rejects oversized trees" do
    source.seed!
    workspace.write("environment/big", "x" * (described_class::MAX_BYTES + 1))
    expect(source.validate).to include(a_string_matching(/exceeds/))
  end
end
