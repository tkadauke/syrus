require "rails_helper"

RSpec.describe AdminMysql::AdminPages do
  it "hides the admin page when the app is not using MySQL" do
    allow(AdminMysql).to receive(:mysql?).and_return(false)

    expect(described_class.admin_pages).to eq([])
  end

  it "declares the MySQL admin route when MySQL is available" do
    allow(AdminMysql).to receive(:mysql?).and_return(true)

    expect(described_class.admin_pages).to contain_exactly(
      include(
        id: "admin_mysql.mysql",
        label_key: "admin_mysql:nav_mysql",
        path: "/admin/mysql",
        component: "admin_mysql/AdminMysql",
        group_id: "observability"
      )
    )
  end
end
