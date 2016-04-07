class Competition < ActiveRecord::Base
  self.table_name = "Competitions"
  # FIXME Tests fail with "Unknown primary key for table Competitions in model Competition."
  #       when not setting the primary key explicitly. I have
  #       no clue why... (th, 2015-09-19)
  self.primary_key = "id"

  has_many :registrations, foreign_key: "competitionId"
  has_many :results, foreign_key: "competitionId"
  has_many :competition_delegates, dependent: :delete_all
  has_many :delegates, through: :competition_delegates
  has_many :competition_organizers, dependent: :delete_all
  has_many :organizers, through: :competition_organizers
  has_many :media, class_name: "CompetitionMedium", foreign_key: "competitionId", dependent: :delete_all

  ENDS_WITH_YEAR_RE = /\A(.*) (\d{4})\z/
  PATTERN_LINK_RE = /\[\{([^}]+)}\{((https?:|mailto:)[^}]+)}\]/
  PATTERN_TEXT_WITH_LINKS_RE = /\A[^{}]*(#{PATTERN_LINK_RE.source}[^{}]*)*\z/
  MAX_ID_LENGTH = 32
  validates :id, presence: true, uniqueness: true, length: { maximum: MAX_ID_LENGTH },
                 format: { with: /\A[a-zA-Z0-9]+\Z/ }
  validates :name, length: { maximum: 50 },
                   format: { with: ENDS_WITH_YEAR_RE }
  MAX_CELL_NAME_LENGTH = 45
  validates :cellName, length: { maximum: MAX_CELL_NAME_LENGTH },
                       format: { with: ENDS_WITH_YEAR_RE }
  validates :venue, format: { with: PATTERN_TEXT_WITH_LINKS_RE }
  validates :website, format: { with: /\Ahttps?:\/\/.*\z/ }, allow_blank: true

  NEARBY_DISTANCE_KM_WARNING = 500
  NEARBY_DISTANCE_KM_DANGER = 200
  NEARBY_DISTANCE_KM_INFO = 200
  NEARBY_DAYS_WARNING = 90
  NEARBY_DAYS_DANGER = 30
  NEARBY_DAYS_INFO = 365
  NEARBY_INFO_COUNT = 8

  # https://www.worldcubeassociation.org/regulations/guidelines.html#8a4++
  SHOULD_BE_ANNOUNCED_GTE_THIS_MANY_DAYS = 29

  # We have stricter validations for confirming a competition
  [:cityName, :countryId, :venue, :venueAddress, :website, :latitude, :longitude].each do |field|
    validates field, presence: true, if: :isConfirmed?
  end
  validate :must_have_at_least_one_event, if: :isConfirmed?
  def must_have_at_least_one_event
    if events.length == 0
      errors.add(:eventSpecs, "Competition must have at least one event")
    end
  end

  validate :must_have_at_least_one_delegate, if: :isConfirmed?
  def must_have_at_least_one_delegate
    if delegate_ids.length == 0
      errors.add(:delegate_ids, "Competition must have at least one WCA delegate")
    end
  end

  # Currently we don't have a history of who was a delegate and when. Hence we need this
  # validation, so people cannot pass a non-delegate as a delegate (even for an old comp).
  # See https://github.com/cubing/worldcubeassociation.org/issues/185#issuecomment-168402252
  # Once that is done, we'll be able to change this validation to work on old competitions.
  validate :delegates_must_be_delegates
  def delegates_must_be_delegates
    if !self.delegates.all?(&:any_kind_of_delegate?)
      errors.add(:delegate_ids, "are not all delegates")
    end
  end

  before_validation :clone_competition, on: [:create]
  def clone_competition
    if competition_id_to_clone.present?
      competition_to_clone = Competition.find_by_id(competition_id_to_clone)
      if competition_to_clone
        attributes = competition_to_clone.attributes
        # Don't clone id, name, and cellName.
        attributes.delete("id")
        attributes.delete("name")
        attributes.delete("cellName")
        # Make sure the new competition is not publicly visible and is open for
        # editing.
        attributes["showAtAll"] = false
        attributes["isConfirmed"] = false
        assign_attributes(attributes)
        self.organizers |= competition_to_clone.organizers
        self.delegates |= competition_to_clone.delegates
      else
        errors.add(:competition_id_to_clone, "invalid")
      end
    end
  end

  attr_writer :start_date, :end_date
  before_validation :unpack_dates
  validate :dates_must_be_valid
  validate :events_must_be_valid

  alias_attribute :latitude_microdegrees, :latitude
  alias_attribute :longitude_microdegrees, :longitude
  attr_accessor :longitude_degrees, :latitude_degrees
  before_validation :compute_coordinates

  before_validation :cleanup_event_specs
  def cleanup_event_specs
    self.eventSpecs ||= ""
  end

  before_validation :create_id_and_cell_name
  def create_id_and_cell_name
    m = ENDS_WITH_YEAR_RE.match(name)
    if m
      name_without_year = m[1]
      year = m[2]
      if id.blank?
        # Generate competition id from name
        # By replacing accented chars with their ascii equivalents, and then
        # removing everything that isn't a digit or a character.
        safe_name_without_year = ActiveSupport::Inflector.transliterate(name_without_year).gsub(/[^a-z0-9]+/i, '')
        self.id = safe_name_without_year[0...(MAX_ID_LENGTH - year.length)] + year
      end
      if cellName.blank?
        year = " " + year
        self.cellName = name_without_year.truncate(MAX_CELL_NAME_LENGTH - year.length) + year
      end
    end
  end

  attr_accessor :competition_id_to_clone

  attr_writer :delegate_ids, :organizer_ids
  def delegate_ids
    @delegate_ids || delegates.map(&:id).join(",")
  end
  def organizer_ids
    @organizer_ids || organizers.map(&:id).join(",")
  end
  before_validation :unpack_delegate_organizer_ids
  def unpack_delegate_organizer_ids
    # This is a mess. When changing competition ids, the calls to delegates=
    # and organizers= below will cause database writes with a new competition_id.
    # We hack around this by pretending our id actually didn't change, and then
    # we restore it at the end. This means we'll preseve our existing
    # CompetitionOrganizer and CompetitionDelegate rows rather than creating new ones.
    # We'll fix their competition_id below in update_foreign_keys_when_id_changes.
    new_id = self.id
    self.id = id_was

    if @delegate_ids
      self.delegates = @delegate_ids.split(",").map { |id| User.find(id) }
    end
    if @organizer_ids
      self.organizers = @organizer_ids.split(",").map { |id| User.find(id) }
    end

    self.id = new_id
  end

  # Workaround for PHP code that requires these tables to be clean.
  # Once we're in all railsland, this can go, and we can add a script
  # that checks our database sanity instead.
  after_save :remove_non_existent_organizers_and_delegates
  def remove_non_existent_organizers_and_delegates
    CompetitionOrganizer.where(competition_id: id).where.not(organizer_id: organizers.map(&:id)).delete_all
    CompetitionDelegate.where(competition_id: id).where.not(delegate_id: delegates.map(&:id)).delete_all
  end

  # This is kind of scary. Whenever a competition's id changes, We need to
  # remember all the places in our database that refer to competition ids, and
  # update them. We can get rid of all this once we're done with
  # https://github.com/cubing/worldcubeassociation.org/issues/91.
  after_save :update_foreign_keys_when_id_changes
  def update_foreign_keys_when_id_changes
    if id_change
      Result.where(competitionId: id_was).update_all(competitionId: id)
      Registration.where(competitionId: id_was).update_all(competitionId: id)
      Scramble.where(competitionId: id_was).update_all(competitionId: id)
      CompetitionMedium.where(competitionId: id_was).update_all(competitionId: id)
      CompetitionDelegate.where(competition_id: id_was).update_all(competition_id: id)
      CompetitionOrganizer.where(competition_id: id_was).update_all(competition_id: id)
    end
  end

  attr_accessor :editing_user_id
  validate :user_cannot_demote_themself
  def user_cannot_demote_themself
    if editing_user_id
      editing_user = User.find(editing_user_id)
      unless editing_user.can_manage_competition?(self)
        errors.add(:delegate_ids, "You cannot demote yourself")
        errors.add(:organizer_ids, "You cannot demote yourself")
      end
    end
  end

  validate :registration_must_close_after_it_opens
  def registration_must_close_after_it_opens
    if use_wca_registration?
      if !registration_open
        errors.add(:registration_open, "required")
      end
      if !registration_close
        errors.add(:registration_close, "required")
      end
      if registration_open && registration_close && !(registration_open < registration_close)
        errors.add(:registration_close, "registration close must be after registration open")
      end
    end
  end

  attr_reader :receive_registration_emails
  def receive_registration_emails=(r)
    @receive_registration_emails = ActiveRecord::Type::Boolean.new.type_cast_from_database(r)
  end

  def managers
    (organizers + delegates).uniq
  end

  def receiving_registration_emails?(user_id)
    competition_delegate = competition_delegates.find_by_delegate_id(user_id)
    if competition_delegate && competition_delegate.receive_registration_emails
      return true
    end
    competition_organizer = competition_organizers.find_by_organizer_id(user_id)
    if competition_organizer && competition_organizer.receive_registration_emails
      return true
    end

    return false
  end

  def can_receive_registration_emails?(user_id)
    competition_delegate = competition_delegates.find_by_delegate_id(user_id)
    if competition_delegate
      return true
    end
    competition_organizer = competition_organizers.find_by_organizer_id(user_id)
    if competition_organizer
      return true
    end

    return false
  end

  after_save :update_receive_registration_emails
  def update_receive_registration_emails
    if editing_user_id && !@receive_registration_emails.nil?
      competition_delegate = competition_delegates.find_by_delegate_id(editing_user_id)
      if competition_delegate
        competition_delegate.update_attribute(:receive_registration_emails, @receive_registration_emails)
      end
      competition_organizer = competition_organizers.find_by_organizer_id(editing_user_id)
      if competition_organizer
        competition_organizer.update_attribute(:receive_registration_emails, @receive_registration_emails)
      end
    end
  end

  def registration_opened?
    use_wca_registration? && !registration_not_yet_opened? && !registration_past?
  end

  def registration_not_yet_opened?
    registration_open && Time.now < registration_open
  end

  def registration_past?
    registration_close && registration_close < Time.now
  end

  def longitude_degrees
    longitude_microdegrees / 1e6
  end

  def longitude_degrees=(new_longitude_degrees)
    @longitude_degrees = new_longitude_degrees.to_f
  end

  def longitude_radians
    to_radians longitude_degrees
  end

  def latitude_degrees
    latitude_microdegrees / 1e6
  end

  def latitude_degrees=(new_latitude_degrees)
    @latitude_degrees = new_latitude_degrees.to_f
  end

  def latitude_radians
    to_radians latitude_degrees
  end

  private def compute_coordinates
    unless @latitude_degrees.nil?
      self.latitude_microdegrees = @latitude_degrees * 1e6
    end
    unless @longitude_degrees.nil?
      self.longitude_microdegrees = @longitude_degrees * 1e6
    end
  end

  def events
    # See https://github.com/cubing/worldcubeassociation.org/issues/95 for
    # what these equal signs are about.
    eventSpecs.split.map { |e| Event.find_by_id(e.split("=")[0]) }.sort_by &:rank
  end

  def has_events_with_ids?(event_ids)
    # See https://github.com/cubing/worldcubeassociation.org/issues/95 for
    # what these equal signs are about.
    (event_ids - eventSpecs.split.map { |e| e.split("=")[0] }).empty?
  end

  def has_event?(event)
    self.events.include?(event)
  end

  def belongs_to_region?(region)
    self.countryId == region || self.country.continentId == region
  end

  def contains?(search_param)
    [name, cityName, venue, cellName, countryId, start_date.strftime('%B')].any? do |field|
      field.downcase.include?(search_param.downcase)
    end
  end

  def start_date
    year == 0 || month == 0 || day == 0 ? nil : Date.new(year, month, day)
  end

  def end_date
    endYear = @endYear || year # gross hack to remember the years of a multiyear competition
    endYear == 0 || endMonth == 0 || endDay == 0 ? nil : Date.new(endYear, endMonth, endDay)
  end

  private def unpack_dates
    if @start_date.nil? && !start_date.blank?
      @start_date = start_date.strftime("%F")
    end
    if @start_date.blank?
      self.year = self.month = self.day = 0
    else
      unless /\A\d{4}-\d{2}-\d{2}\z/.match(@start_date)
        errors.add(:start_date, "invalid")
        return false
      end
      self.year, self.month, self.day = @start_date.split("-").map(&:to_i)
      unless Date.valid_date? self.year, self.month, self.day
        errors.add(:start_date, "invalid")
        return false
      end
    end
    if @end_date.nil? && !end_date.blank?
      @end_date = end_date.strftime("%F")
    end
    if @end_date.blank?
      @endYear = self.endMonth = self.endDay = 0
    else
      unless /\A\d{4}-\d{2}-\d{2}\z/.match(@end_date)
        errors.add(:end_date, "invalid")
        return false
      end
      @endYear, self.endMonth, self.endDay = @end_date.split("-").map(&:to_i)
      unless Date.valid_date? @endYear, self.endMonth, self.endDay
        errors.add(:end_date, "invalid")
        return false
      end
    end
  end

  private def dates_must_be_valid
    if !isConfirmed && self.year == 0 && self.month == 0 && self.day == 0 && @endYear == 0 && self.endMonth == 0 && self.endDay == 0
      # If the user left both dates empty, that's a-okay.
      return
    end

    valid_dates = true
    unless Date.valid_date? year, month, day
      valid_dates = false
      errors.add(:start_date, "Invalid start date.")
    end
    unless Date.valid_date? @endYear, endMonth, endDay
      valid_dates = false
      errors.add(:end_date, "Invalid end date.")
    end
    unless valid_dates
      # There's no use continuing validation at this point.
      return
    end

    if end_date < start_date
      errors.add(:end_date, "End date cannot be before start date.")
    end

    if @endYear != year
      errors.add(:end_date, "Competition dates cannot span multiple years.")
    end
  end

  private def events_must_be_valid
    invalid_events = events - Event.all_official - Event.all_deprecated
    unless invalid_events.empty?
      errors.add(:eventSpecs, "invalid event ids: #{invalid_events.map(&:id).join(',')}")
    end
  end

  def nearby_competitions(days, distance)
    Competition.where(
      "ABS(DATEDIFF(?, CONCAT(year, '-', month, '-', day))) <= ? AND id <> ?", start_date, days, id)
      .select { |c| kilometers_to(c) <= distance }
      .sort_by { |c| kilometers_to(c) }
  end

  private def to_radians(degrees)
    degrees * Math::PI / 180
  end

  # Source http://www.movable-type.co.uk/scripts/latlong.html
  def kilometers_to(c)
    6371 *
      Math::sqrt(
        ( (c.longitude_radians - longitude_radians) * Math::cos((c.latitude_radians  + latitude_radians)/2)) ** 2 +
        (c.latitude_radians - latitude_radians) ** 2
      )
  end

  def has_date?
    start_date != nil
  end

  def has_location?
    latitude != 0 && longitude != 0
  end

  def days_until
    start_date ? (start_date - Time.now.to_date).to_i : nil
  end

  def has_date_errors?
    valid?
    !errors[:start_date].empty? || !errors[:end_date].empty? || (!showAtAll && days_until && days_until < SHOULD_BE_ANNOUNCED_GTE_THIS_MANY_DAYS)
  end

  def dangerously_close_to?(c)
    if !c.start_date || !self.start_date
      return false
    end
    days_until = (c.start_date - self.start_date).to_i
    self.kilometers_to(c) <= NEARBY_DISTANCE_KM_DANGER && days_until.abs < NEARBY_DAYS_DANGER
  end

  def results_uploaded?
    Result.exists?(competitionId: self.id)
  end

  def user_can_view?(user)
    self.showAtAll || (user && user.can_manage_competition?(self))
  end

  def in_progress?
    (start_date..end_date).cover? Date.today
  end

  def is_over?
    !!end_date && end_date < Date.today
  end

  def events_with_podium_results
    light_results_from_relation(results.where(roundId: Round.final_rounds.map(&:id)).where("pos >= 1 AND pos <= 3")).group_by(&:event).sort_by { |event, results| event.rank }
  end

  def winning_results
    light_results_from_relation(results.where(roundId: Round.final_rounds.map(&:id)).where("pos = 1")).sort_by { |r| r.event.rank }
  end

  def persons_with_results
    light_results_from_relation(results).group_by(&:personName).sort_by { |personName, results| personName }.map do |personName, results|
      results.sort_by! { |r| [ r.event.rank, -r.round.rank ] }

      # Mute (soften) each result that wasn't the competitor's last for the event.
      last_event = nil
      results.each do |result|
        result.muted = (result.event == last_event)
        last_event = result.event
      end

      [ personName, results.sort_by { |r| [ r.event.rank, -r.round.rank ] } ]
    end
  end

  def events_with_rounds_with_results
    light_results_from_relation(results).group_by(&:event).sort_by { |event, results| event.rank }.map do |event, results|
      rounds_with_results = results.group_by(&:round).sort_by { |format, results| format.rank }.map do |round, results|
        [ round, results.sort_by(&:pos) ]
      end

      [ event, rounds_with_results ]
    end
  end

  private def light_results_from_relation(relation)
    ActiveRecord::Base.connection.execute(relation.to_sql).each(as: :hash).map do |r|
      LightResult.new(r)
    end
  end

  def started?
    !!start_date && start_date < Date.today
  end

  def country_name
    country = Country.find_by_id(countryId)
    country ? country.name : nil
  end

  def self.search(query, params: {})
    competitions = Competition.where(showAtAll: true)

    if params[:country_iso2].present?
      country = Country.find_by_iso2(params[:country_iso2])
      if !country
        raise WcaExceptions::BadApiParameter, "Invalid country_iso2: '#{params[:country_iso2]}'"
      end
      competitions = competitions.where(countryId: country.id)
    end

    if params[:start].present?
      start_date = Date.safe_parse(params[:start])
      if !start_date
        raise WcaExceptions::BadApiParameter, "Invalid start: '#{params[:start]}'"
      end
      competitions = competitions.where("CAST(CONCAT(year,'-',month,'-',day) as Date) >= ?", start_date)
    end

    if params[:end].present?
      end_date = Date.safe_parse(params[:end])
      if !end_date
        raise WcaExceptions::BadApiParameter, "Invalid end: '#{params[:end]}'"
      end
      competitions = competitions.where("CAST(CONCAT(year,'-',endMonth,'-',endDay) as Date) <= ?", end_date)
    end

    if query.present?
      sql_query = "%#{query}%"
      competitions = competitions.where("id LIKE :sql_query OR name LIKE :sql_query OR cellName LIKE :sql_query OR cityName LIKE :sql_query OR countryId LIKE :sql_query", sql_query: sql_query).order(year: :desc, month: :desc, day: :desc)
    end

    if params[:sort].present?
      params[:sort].split(",").each do |field|
        order = field.start_with?("-") ? :desc : :asc

        case field
        when "start_date", "-start_date"
          competitions = competitions.order(year: order, month: order, day: order)
        when "end_date", "-end_date"
          competitions = competitions.order(year: order, endMonth: order, endDay: order)
        else
          raise WcaExceptions::BadApiParameter, "Unrecognized sort field: '#{field}'"
        end
      end
    end

    competitions
  end

  def serializable_hash(options = nil)
    json = {
      class: self.class.to_s.downcase,
      url: Rails.application.routes.url_helpers.competition_path(self),

      id: id,
      name: name,
      website: website,
      short_name: cellName,
      city: cityName,
      country_iso2: country.iso2,
      start_date: start_date,
      end_date: end_date,
      delegates: delegates,
      organizers: organizers,
    }
    json
  end
end
