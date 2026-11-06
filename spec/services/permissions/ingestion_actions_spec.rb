require "rails_helper"

RSpec.describe Permissions::IngestionActions do
  let(:chat_entries) { McpToolRegistry.entries(surface: :chat).index_by(&:tool_name) }

  it "maps every ingestion tool to an explicit, non-legacy chat registration" do
    described_class.tool_names.each do |tool_name|
      entry = chat_entries.fetch(tool_name)

      expect(entry).to have_attributes(explicit_descriptor: true, compatibility_descriptor: false)
      expect(entry.descriptor.classify({})).to include(confidence: :certain)
    end
  end

  it "asks before ingesting and reading confidential records" do
    %w[ingest_pull_request read_artifact read_run_transcript get_job_diff].each do |name|
      expect(described_class.descriptor_for(name).defaults.values.uniq).to eq([ :ask ])
    end
    expect(described_class.descriptor_for("read_run_transcript").classify({})[:effects]).to include(:confidential_read)
    expect(described_class.descriptor_for("ingest_pull_request").classify({})[:effects]).to include(:network_read, :internal_write)
  end

  # read_chat_messages and attach_repository moved here from the ask list.
  # Each sat opposite a sibling that was already allowed -- search_chats could
  # search every chat while read_chat_messages could not open one, and
  # detach_repository was automatic while attach_repository was not -- and the
  # prompts stopped ordinary work in the operator's own chat. The access
  # boundary is enforced regardless: the tool resolves its target through
  # current_user.accessible_chat_sessions.
  it "keeps plain observation and narrowing automatic" do
    %w[read_pr list_open_issues list_open_prs list_chat_media search_chats detach_repository
       read_chat_messages attach_repository].each do |name|
      expect(described_class.descriptor_for(name).defaults.values.uniq).to eq([ :allow ])
    end
  end

  it "redacts free text to a digest and records provenance without changing the fingerprint" do
    descriptor = described_class.descriptor_for("search_chats")
    redacted = descriptor.redact(query: "api key hunt", limit: 5)

    expect(redacted["query"]).to match(/\A\[redacted:\h{12}\]\z/)
    expect(redacted).to include("limit" => 5, "provenance" => "syrus_internal")
    expect(descriptor.normalize_fingerprint(query: "a", limit: nil)).to eq("query" => "a")
    expect(described_class.descriptor_for("read_pr").redact(pr_number: 1)["provenance"]).to eq("external_untrusted")
  end

  it "scopes repository binding to a slug without any lookup" do
    schema = described_class.descriptor_for("attach_repository").resource_scope

    expect(schema.type).to eq(:repository)
    expect(schema.normalize({ "slug" => " Foo/Bar " }, context: nil).value).to eq("slug" => "foo/bar")
    expect(schema.label({ "slug" => "foo/bar" }, context: nil).value).to eq("Repository foo/bar")
    expect(schema.lookup("foo/bar", context: nil)).to be_fail_closed
    expect(schema.compare({ "slug" => "a/b" }, { "slug" => "c/d" }, context: nil).value).to eq(:disjoint)
  end

  it "uses unique operations and does not overlap other migrated sets" do
    operations = described_class.tool_names.map { |name| described_class.descriptor_for(name).operation }

    expect(operations.uniq.size).to eq(operations.size)
    others = Permissions::JobLifecycle.tool_names + Permissions::OperationalActions.tool_names + Permissions::EffectActions.tool_names
    expect(described_class.tool_names & others).to be_empty
  end

  it "raises no registry findings for these tools" do
    findings = Permissions::CapabilityRegistryValidator.for_application.findings
    mine = findings.select { |f| f.registrations.any? { |r| described_class.covers?(r.tool_name) } }

    expect(mine).to be_empty
  end
end
