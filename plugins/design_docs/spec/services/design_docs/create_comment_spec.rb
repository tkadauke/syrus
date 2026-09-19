require "rails_helper"

RSpec.describe DesignDocs::CreateComment do
  let(:owner) { Factories.user(email_address: "owner@example.com") }
  let(:collaborator) { Factories.user(email_address: "collaborator@example.com") }

  it "rejects stale anchor selections before taking the document write lock" do
    design_doc = DesignDoc.create!(
      owner_user: owner,
      title: "Anchor validation",
      markdown: "Alpha beta gamma",
      visibility: "private"
    )
    version = design_doc.versions.create!(markdown: design_doc.markdown, version_number: 1, actor_kind: "user", actor_user: owner)
    design_doc.update!(current_version: version)
    design_doc.collaborators.create!(user: collaborator, role: "editor", added_by_user: owner)

    expect(design_doc).not_to receive(:lock!)

    expect {
      described_class.call(
        design_doc: design_doc,
        user: collaborator,
        attributes: {
          body: "This selection was made against an old draft",
          start_offset: 0,
          end_offset: 5,
          selected_markdown: "missing selection"
        }
      )
    }.to raise_error(ActiveRecord::RecordInvalid)
      .and change(DesignDocs::DesignDocThread, :count).by(0)
      .and change(DesignDocs::DesignDocVersion, :count).by(0)
  end
end
