require "rails_helper"

RSpec.describe SdlcPipeline::Filter do
  let(:user) { Factories.user(email_address: "owner@example.com") }
  let(:other_user) { Factories.user(email_address: "other@example.com") }
  let(:repository) { Factories.repository(user: user) }
  let(:epic) { Factories.epic(repository: repository, user: user, title: "Release safety") }
  let!(:owned) { Factories.job_record(repository: repository, user: user, owner_user: user, epic: epic, issue_title: "Harden rollout") }
  let!(:other) { Factories.job_record(repository: repository, user: user, owner_user: other_user, issue_number: 99, issue_title: "Unrelated work") }

  it "compiles nested AND/OR/NOT expressions over pipeline cohort fields" do
    tree = {
      "and" => [
        { "or" => [
          { "field" => "epic_id", "op" => "is_one_of", "value" => [ epic.id ] },
          { "field" => "job_id", "op" => "is_one_of", "value" => [ other.id ] }
        ] },
        { "not" => { "field" => "owner_user_id", "op" => "is", "value" => other_user.id } }
      ]
    }

    expect(described_class.from_tree(tree, user: user).apply(Job.all)).to contain_exactly(owned)
  end

  it "searches Job and Epic identity and title fields" do
    title_filter = described_class.from_tree(
      { "and" => [ { "field" => "search", "op" => "contains", "value" => "Release safety" } ] }, user: user
    )
    id_filter = described_class.from_tree(
      { "and" => [ { "field" => "search", "op" => "contains", "value" => other.id.to_s } ] }, user: user
    )
    job_slug_filter = described_class.from_tree(
      { "and" => [ { "field" => "search", "op" => "contains", "value" => "JOB-#{other.id}" } ] }, user: user
    )
    epic_slug_filter = described_class.from_tree(
      { "and" => [ { "field" => "search", "op" => "contains", "value" => "EPIC-#{epic.number}" } ] }, user: user
    )
    oversized_slug_filter = described_class.from_tree(
      { "and" => [ { "field" => "search", "op" => "contains", "value" => "JOB-#{'9' * 30} EPIC-#{'9' * 30}" } ] }, user: user
    )

    expect(title_filter.apply(Job.all)).to contain_exactly(owned)
    expect(id_filter.apply(Job.all)).to include(other)
    expect(job_slug_filter.apply(Job.all)).to contain_exactly(other)
    expect(epic_slug_filter.apply(Job.all)).to contain_exactly(owned)
    expect(oversized_slug_filter.apply(Job.all)).to be_empty
  end

  describe "associated chat filtering" do
    let(:empty_chat) { ChatSession.create!(user: user, title: "Empty") }
    let(:first_chat) { ChatSession.create!(user: user, title: "First") }
    let(:second_chat) { ChatSession.create!(user: user, title: "Second") }
    let(:associated_epic) { Factories.epic(repository: repository, user: user, title: "Associated release") }
    let!(:first_job) { Factories.job_record(repository: repository, user: user, issue_number: 101, issue_title: "Shared rollout") }
    let!(:shared_job) { Factories.job_record(repository: repository, user: user, owner_user: other_user, epic: associated_epic, issue_number: 102, issue_title: "Shared rollout") }
    let!(:second_job) { Factories.job_record(repository: repository, user: user, issue_number: 103, issue_title: "Second only") }

    before do
      associate(first_chat, first_job, "first")
      associate(first_chat, shared_job, "shared-first")
      associate(second_chat, shared_job, "shared-second")
      associate(second_chat, second_job, "second")
    end

    it "handles chats with zero, one, and multiple Jobs without duplicate matches" do
      expect(apply_associated(:is, empty_chat.id)).to be_empty

      one_job_chat = ChatSession.create!(user: user, title: "One")
      associate(one_job_chat, first_job, "one")
      expect(apply_associated(:is, one_job_chat.id)).to contain_exactly(first_job)

      expect(apply_associated(:is, first_chat.id)).to contain_exactly(first_job, shared_job)
      expect(apply_associated(:is_one_of, [ first_chat.id, second_chat.id ]).pluck(:id))
        .to contain_exactly(first_job.id, shared_job.id, second_job.id)
    end

    it "supports all positive and negative operators" do
      expect(apply_associated(:is, first_chat.id)).to contain_exactly(first_job, shared_job)
      expect(apply_associated(:is_one_of, [ first_chat.id ])).to contain_exactly(first_job, shared_job)
      expect(apply_associated(:is_not, first_chat.id)).to contain_exactly(owned, other, second_job)
      expect(apply_associated(:is_none_of, [ first_chat.id, second_chat.id ])).to contain_exactly(owned, other)
    end

    it "composes in nested AND/OR/NOT expressions with search, Job, Epic, and owner filters" do
      tree = {
        "and" => [
          { "field" => "search", "op" => "contains", "value" => "rollout" },
          { "or" => [
            { "and" => [
              { "field" => "associated_chat_id", "op" => "is", "value" => first_chat.id },
              { "field" => "epic_id", "op" => "is", "value" => associated_epic.id }
            ] },
            { "field" => "job_id", "op" => "is", "value" => first_job.id }
          ] },
          { "not" => { "field" => "owner_user_id", "op" => "is", "value" => other_user.id } }
        ]
      }

      expect(described_class.from_tree(tree, user: user).apply(Job.all)).to contain_exactly(first_job)
    end

    it "returns no matches for another user's or deleted chats" do
      foreign_chat = ChatSession.create!(user: other_user, title: "Private")
      deleted_chat = ChatSession.create!(user: user, title: "Deleted", deleted_at: Time.current)
      associate(foreign_chat, first_job, "foreign")
      associate(deleted_chat, second_job, "deleted")

      expect(apply_associated(:is_one_of, [ foreign_chat.id, deleted_chat.id ])).to be_empty
      expect(apply_associated(:is_none_of, [ foreign_chat.id, deleted_chat.id ])).to contain_exactly(owned, other, first_job, shared_job, second_job)
    end

    it "uses a constant number of queries as selected chats and associated Jobs grow" do
      baseline = select_queries { apply_associated(:is_one_of, [ first_chat.id ]).load }
      chat_ids = 20.times.map do |index|
        chat = ChatSession.create!(user: user, title: "Scale #{index}")
        job = Factories.job_record(repository: repository, user: user, issue_number: 200 + index)
        associate(chat, job, "scale-#{index}")
        chat.id
      end
      scaled = select_queries { apply_associated(:is_one_of, chat_ids).load }

      expect(baseline.length).to eq(1)
      expect(scaled.length).to eq(1)
      expect(scaled.first).to include("chat_sessions", "chat_proposals")
    end

    def apply_associated(op, value)
      tree = { "and" => [ { "field" => "associated_chat_id", "op" => op.to_s, "value" => value } ] }
      described_class.from_tree(tree, user: user).apply(Job.all)
    end

    def associate(chat, job, slug)
      chat.proposals.create!(kind: "job", slug: slug, title: slug.titleize, body: "Body", state: "confirmed", job: job)
    end

    def select_queries
      queries = []
      callback = ->(_name, _start, _finish, _id, payload) do
        queries << payload[:sql] if payload[:sql].match?(/\ASELECT/i) && payload[:name] != "SCHEMA"
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
      queries
    end
  end
end
