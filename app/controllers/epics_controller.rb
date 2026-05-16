class EpicsController < ApplicationController
  def show
    @epic = Current.user.epics
                        .includes(:repository, { jobs: :repository }, { dependencies: :depends_on_epic }, { dependent_links: :epic })
                        .find(params[:id])
  end
end
