require 'date'


class CalendarEvent
  attr_reader :weekday, :start_time, :end_time, :section

  def initialize(place, weekday, start_time, end_time, section, **override)
    @place = place
    @weekday = weekday
    @start_time = start_time
    @end_time = end_time
    @section = section

    override.each do |key, value|
      instance_variable_set("@#{key}", value)
    end

    @created_at = DateTime.now
    @updated_at = DateTime.now
  end

  def first_day
    @first_day ||= period_start + (@weekday - period_start.wday) % 7
  end

  def last_day
    @last_day ||= period_end
  end

  def end_before(datetime)
    date = Date.new(datetime.year, datetime.month, datetime.day)

    @updated_at = datetime
    @last_day = date - 1
  end

  def start_after(datetime)
    date = Date.new(datetime.year, datetime.month, datetime.day)
    next_occurrence = date + (weekday - date.wday) % 7

    @first_day = next_occurrence
  end

  def start_datetime
    DateTime.new(first_day.year, first_day.month, first_day.day, @start_time[0], @start_time[1], 0)
  end

  def end_datetime
    DateTime.new(first_day.year, first_day.month, first_day.day, @end_time[0], @end_time[1], 0)
  end

  def title
    @title ||= "#{@place.event_title} #{@section.downcase}"
  end

  def desc
    start_t = start_time.map { |t| t.to_s.rjust(2, '0') }.join('h')
    end_t = end_time.map { |t| t.to_s.rjust(2, '0') }.join('h')

    event_desc = "#{title} (#{ Date::DAYNAMES[@weekday]}, #{start_t}-#{end_t}, "\
      "from #{first_day.strftime('%d/%m/%Y')} to #{last_day.strftime('%d/%m/%Y')})"
    event_desc += " - #{notice}" if notice

    event_desc
  end

  def period_start
    @period_start ||= @place.season_from
  end

  def period_end
    @period_end ||= @place.season_to
  end

  def notice
    @notice ||= begin
      return if @place.nil?
      @place.notice
    end
  end

  def notice_details
    @notice_details ||= begin
      return if @place.nil?
      @place.notice_details
    end
  end

  def created_at
    @created_at
  end

  def updated_at
    @updated_at
  end

  def static_hash
    CalendarEvent.hash_of(static_data)
  end

  def dynamic_hash
    CalendarEvent.hash_of(dynamic_data)
  end

  def dynamic_active_hash
    CalendarEvent.hash_of(dynamic_active_data)
  end

  def without_period(exclude_period_start, exclude_period_end)
    return [copy] if exclude_period_start > last_day || exclude_period_end < first_day

    new_events = []

    if exclude_period_start > first_day
      event_before = copy
      event_before.end_before(exclude_period_start)
      new_events << event_before
    end

    if exclude_period_end < last_day
      event_after = copy
      event_after.start_after(exclude_period_end)
      new_events << event_after
    end

    new_events
  end

  def overlap(other)
    !(other.last_day < first_day || other.first_day > last_day)
  end

  def seen!
    @seen = true
  end

  def seen?
    @seen
  end

  def copy
    CalendarEvent.from_json(to_json)
  end

  def to_json(options=nil)
    all_data.to_json(options)
  end

  def self.from_json(json_data)
    # Because we dump as JSON, we might need to parse it back
    data = if json_data.is_a?(String)
      JSON.parse(json_data)
    else
      json_data
    end

    # Create a new object
    object = new(nil, nil, nil, nil, nil)

    # Set the instance variables
    data.each do |key, value|
      if value.is_a?(String)
        if value.match?(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
          value = DateTime.parse(value)
        elsif value.match?(/^\d{4}-\d{2}-\d{2}$/)
          value = Date.parse(value)
        end
      end

      object.instance_variable_set("@#{key}", value)
    end

    object
  end

  def to_s
    all_data.to_s
  end

  def <=>(other)
    left = [first_day, start_time, end_time, section]
    right = [other.first_day, other.start_time, other.end_time, other.section]

    left <=> right
  end

  private

  attr_reader :place

  def self.hash_of(data)
    Digest::SHA256.hexdigest(JSON.dump(data.to_a.sort_by { |k, _v| k }))
  end

  def static_data
    {
      title: title,
      weekday: weekday,
      start_time: start_time,
      end_time: end_time,
      period_start: period_start,
      period_end: period_end,
      section: section,
    }
  end

  def dynamic_data
    static_data.merge({
      notice: notice,
      notice_details: notice_details,
    })
  end

  def dynamic_active_data
    dynamic_data.merge({
      first_day: first_day,
      last_day: last_day,
    })
  end

  def all_data
    dynamic_data.merge({
      first_day: first_day,
      start_datetime: start_datetime,
      end_datetime: end_datetime,
      created_at: created_at,
      updated_at: updated_at,
      last_day: last_day,
    })
  end
end

