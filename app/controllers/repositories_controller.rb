class RepositoriesController < ApplicationController
  before_action :load_repository, only: %i[ edit update destroy poll archive unarchive ]

  def index
    repos = Current.user.repositories.order(:owner, :name)
    @active_repositories   = repos.active
    @archived_repositories = repos.archived
  end

  def new
    @repository = Current.user.repositories.build(default_branch: "main", trigger_label: "syrus")
  end

  def branches
    owner = params[:owner].to_s.strip
    name  = params[:name].to_s.strip
    if owner.blank? || name.blank?
      render json: { error: "missing_params" } and return
    end
    result = GithubClient.for(Current.user).repo_branches("#{owner}/#{name}")
    render json: result
  rescue Octokit::NotFound, Octokit::Unauthorized, Octokit::Forbidden
    render json: { error: "not_found" }
  rescue StandardError
    render json: { error: "error" }
  end

  def create
    @repository = Current.user.repositories.build(repository_params)
    if @repository.save
      redirect_to repositories_path, notice: "Repository #{@repository.slug} added."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @repository.update(repository_params)
      redirect_to repositories_path, notice: "Repository #{@repository.slug} updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @repository.destroy
    redirect_to repositories_path, notice: "Repository removed."
  end

  def poll
    if @repository.archived?
      redirect_to repositories_path, alert: "#{@repository.slug} is archived — unarchive it first."
    else
      PollRepositoryJob.perform_later(@repository.id, force: true)
      redirect_to repositories_path, notice: "Polling #{@repository.slug} now…"
    end
  end

  def archive
    @repository.archive!
    redirect_to repositories_path, notice: "#{@repository.slug} archived."
  end

  def unarchive
    @repository.unarchive!
    redirect_to repositories_path, notice: "#{@repository.slug} unarchived. Re-enable polling to start ingestion again."
  end

  private

  def load_repository
    @repository = Current.user.repositories.find(params[:id])
  end

  def repository_params
    params.expect(repository: [ :owner, :name, :default_branch, :trigger_label, :polling_enabled ])
  end
end
