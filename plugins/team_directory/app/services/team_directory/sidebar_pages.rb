module TeamDirectory
  class SidebarPages
    include Syrus::Plugin::SidebarPage

    # A directory of one person is not a directory. The nav entry stayed
    # hidden below two users when this was a core nav item; keep that.
    def self.sidebar_pages
      return [] unless User.limit(2).count > 1

      [
        {
          id: "team_directory.index",
          label: "Team",
          label_key: "team_directory:nav_team",
          path: "/profiles",
          # TeamDirectory.tsx splits index from detail on `useParams().id`, so
          # the detail path has to be declared or /profiles/9 renders the bare
          # bootstrap shell -- the same gap design_docs had.
          paths: [ "/profiles", "/profiles/:id" ],
          component: "team_directory/TeamDirectory",
          icon: "team",
          order: 50
        }
      ]
    end
  end
end
