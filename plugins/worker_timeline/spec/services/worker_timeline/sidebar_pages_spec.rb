require "rails_helper"

RSpec.describe WorkerTimeline::SidebarPages do
  # The very first User created in an example is auto-promoted to admin
  # (User#promote_first_user_to_admin), regardless of an explicit
  # `admin: false`. Burn that slot up front so `member` below reliably stays
  # non-admin.
  let!(:seed_user) { Factories.user(admin: true) }
  let(:admin) { Factories.user(admin: true) }
  let(:member) { Factories.user(admin: false) }

  def enable_plugin!
    PluginRecord.find_by!(name: "worker_timeline").update!(enabled: true)
  end

  it "is empty when the plugin is disabled" do
    Current.api_user = admin

    expect(described_class.sidebar_pages).to eq([])
  end

  it "is empty for a non-admin even when the plugin is enabled" do
    enable_plugin!
    Current.api_user = member

    expect(described_class.sidebar_pages).to eq([])
  end

  it "is empty when there is no current user" do
    enable_plugin!

    expect(described_class.sidebar_pages).to eq([])
  end

  it "declares the Worker Timeline sidebar page for an admin once fully enabled" do
    enable_plugin!
    Current.api_user = admin

    expect(described_class.sidebar_pages).to contain_exactly(
      include(
        id: "worker_timeline.macro",
        label: "Worker Timeline",
        label_key: "worker_timeline:nav_worker_timeline",
        path: "/worker_timeline",
        paths: [ "/worker_timeline", "/worker_timeline/workflow" ],
        component: "worker_timeline/WorkerTimeline",
        icon: "timeline"
      )
    )
  end
end
