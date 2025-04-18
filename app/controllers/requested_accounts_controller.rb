# frozen_string_literal: true

#= Controller for requesting new wiki accounts and processing those requests
class RequestedAccountsController < ApplicationController
  respond_to :html
  before_action :set_course, except: [:index, :create_all_accounts]
  before_action :check_creation_permissions,
                only: %i[show create_accounts enable_account_requests destroy]

  # This creates (or updates) a RequestedAccount, which is a username and email
  # for a user who wants to create a wiki account (but may not be able to do so
  # because of a shared IP that has hit the new account limit).
  def request_account
    redirect_if_passcode_invalid { return }
    # If there is already a request for a certain username for this course, then
    # it's probably the same user who put in the wrong email the first time.
    # Just overwrite the email with the new one in this case.
    handle_existing_request { return }
    @requested = RequestedAccount.create(course: @course,
                                         username: params[:username],
                                         email: params[:email])
    handle_invalid_request { return }

    unless params[:create_account_now] == 'true'
      render json: { message: I18n.t('courses.new_account_submitted') }
      return
    end
    result = create_account(@requested)
    if result[:success]
      render json: { message: result.values.first }
    else
      render json: { message: result.values.first }, status: :internal_server_error
    end
  end

  # Sets the flag on a course so that clicking 'Sign Up' opens the Request Account
  # modal instead of redirecting to the mediawiki account creation flow.
  def enable_account_requests
    @course.flags[:register_accounts] = true
    @course.save
  end

  # List of requested accounts for a user's courses. @courses set in before action
  def index
    raise_unauthorized_exception unless user_signed_in? && current_user.admin?
    respond_to do |format|
      format.html do
        @courses = all_requested_accounts
        render
      end
      format.json { render json: { requested_accounts: RequestedAccount.any? } }
    end
  end

  # List of requested accounts for a course.
  def show; end

  def destroy
    # raise exception unless requestedaccount belongs to course
    requested_account = RequestedAccount.find_by(id: params[:id])
    raise_unauthorized_exception unless @course.id == requested_account.course_id
    requested_account.delete
    redirect_back fallback_location: '/'
  end

  # Try to create each of the requested accounts for a course, and show the
  # result for each.
  def create_accounts
    @results = []
    @course.requested_accounts.each do |requested_account|
      @results << create_account(requested_account)
    end
  end

  def create_all_accounts
    raise_unauthorized_exception unless user_signed_in? && current_user.admin?
    @courses = all_requested_accounts
    @results = RequestedAccount.all.map { |account| create_account(account) }

    render :index
  end

  private

  def all_requested_accounts
    RequestedAccount.all.includes(:course).group_by { |account| account.course.title }
  end

  def create_account(requested_account)
    creation_attempt = CreateRequestedAccount.new(requested_account, current_user)
    result = creation_attempt.result
    return result unless result[:success]
    # If it was successful, enroll the user in the course
    user = creation_attempt.user
    JoinCourse.new(course: requested_account.course,
                   user:,
                   role: CoursesUsers::Roles::STUDENT_ROLE)
    result
  end

  def check_creation_permissions
    return if user_signed_in? && @course && current_user.can_edit?(@course)
    raise_unauthorized_exception
  end

  def raise_unauthorized_exception
    raise ActionController::InvalidAuthenticityToken, 'Unauthorized'
  end

  def set_course
    @course = Course.find_by(slug: params[:course_slug])
  end

  def redirect_if_passcode_invalid
    return if passcode_valid?
    redirect_to '/errors/incorrect_passcode.json'
    yield
  end

  def handle_invalid_request
    return if @requested.valid?
    render json: { message: @requested.invalid_email_message }, status: :unprocessable_entity
    yield
  end

  def passcode_valid?
    return true if @course.passcode.blank?
    params[:passcode] == @course.passcode
  end

  def handle_existing_request
    existing_request = RequestedAccount.find_by(course: @course, username: params[:username])
    return unless existing_request
    existing_request.update(email: params[:email])
    render json: { message: existing_request.updated_email_message }
    yield
  end
end
