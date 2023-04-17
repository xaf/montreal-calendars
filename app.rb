#!/usr/bin/env ruby

require 'fileutils'
require 'icalendar'
require 'icalendar/tzinfo'
require 'json'
require 'mechanize'

class CalendarEventList < Array
  def upsert_all(events)
    events.each do |event|
      upsert(event, false)
    end

    cleanup
  end

  def upsert(event, cleanup=true)
    index = self.rindex do |e|
      e.static_hash == event.static_hash
    end

    unless index.nil?
      match = self[index]
      if event.dynamic_hash == match.dynamic_hash
        # puts "No change for #{match.desc} (sta: #{match.static_hash}, dyn: #{match.dynamic_hash})"
        return
      end

      # puts "Updating #{event.desc}"
      now = DateTime.now
      match.end_after(now)
      event.start_after(now)
    end

    push(event)
    cleanup if cleanup
  end

  def expire_date
    @expire_date ||= begin
      date = DateTime.now
      DateTime.new(date.year - 2, date.month, date.day, date.hour, date.minute, date.second)
    end
  end

  def cleanup
    self.reject! do |event|
      event.last_day < event.first_day || event.last_day < expire_date
    end
  end

  def push(event)
    raise ArgumentError, 'Not a CalendarEvent' unless event.is_a?(CalendarEvent)

    super(event)
    self.sort!
  end
end

class CalendarEvent
  attr_reader :weekday, :start_time, :end_time, :section

  def initialize(place, weekday, start_time, end_time, section)
    @place = place
    @weekday = weekday
    @start_time = start_time
    @end_time = end_time
    @section = section

    @created_at = DateTime.now
    @updated_at = DateTime.now
  end

  def first_day
    @first_day ||= @place.season_from + (@weekday - @place.season_from.wday) % 7
  end

  def last_day
    @last_day ||= period_end
  end

  def end_after(datetime)
    date = DateTime.new(datetime.year, datetime.month, datetime.day, 0, 0, 0)

    @updated_at = datetime
    @last_day = date - 1
  end

  def start_after(datetime)
    date = DateTime.new(datetime.year, datetime.month, datetime.day, 0, 0, 0)
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

    "#{title} (#{ Date::DAYNAMES[@weekday]}, #{start_t}-#{end_t})"
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

  def to_json(options)
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
      if value.is_a?(String) && value.match?(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
        value = DateTime.parse(value)
      end

      object.instance_variable_set("@#{key}", value)
    end

    object
  end

  def to_s
    all_data.to_s
  end

  def <=>(other)
    [first_day, start_time, end_time, section] <=> [other.first_day, other.start_time, other.end_time, other.section]
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

class MontrealPlace
  def initialize(place, language='fr')
    @place = place.downcase
    @language = language.downcase
  end

  def update
    save_data
    save_ical
  end

  def url
    @url ||= if @language == 'en'
      "https://montreal.ca/en/places/#{@place}"
    else
      "https://montreal.ca/lieux/#{@place}"
    end
  end

  def timezone_id
    'America/Montreal'
  end

  def season_from
    season_dates[:from]
  end

  def season_to
    season_dates[:to]
  end

  def event_title
    @event_title ||= contents.at('h2').text.strip
  end

  def notice
    return unless message_bar
    @notice ||= message_bar.at('div.message-bar-heading').text.strip
  end

  def notice_details
    return unless message_bar
    @notice_details ||= message_bar.at('p').text.strip
  end

  def author
    @author = page.at('meta[name="author"]')['content']
  end

  def place_name
    @place_name = page.at('meta[property="og:title"]')['content']
  end

  def address
    @address ||= begin
      address = nil
      page.search('div.list-item-icon-content').each do |item|
        if ['Address', 'Adresse'].include?(item.at('div.list-item-icon-label').text.strip)
          address = item.search('div')[1].
            children.
            map(&:text).
            map(&:strip).
            reject(&:empty?).
            join(', ')
          break
        end
      end
      address
    end
  end

  def image
    @image ||= page.at('meta[property="og:image"]')['content']
  end

  def events
    @events ||= begin
      events = load_data
      events.upsert_all(scrapped_events)
      events
    end
  end

  def to_ical
    cal = Icalendar::Calendar.new

    tz = TZInfo::Timezone.get(timezone_id)
    timezone = tz.ical_timezone(season_from)
    cal.add_timezone(timezone)

    # Find the first date for each day of the week
    events.each do |event|
      cal.event do |e|
        e.uid         = event.dynamic_hash
        e.dtstart     = Icalendar::Values::DateTime.new(event.start_datetime, 'tzid' => timezone_id)
        e.dtend       = Icalendar::Values::DateTime.new(event.end_datetime, 'tzid' => timezone_id)
        e.summary     = event.title

        if notice
          e.summary = "#{event.notice} - #{e.summary}"
          e.description = "#{event.notice} - #{event.notice_details}"
          e.color = "#ffb833"
        else
          e.color = "#00a0e9"
        end

        # e.ip_class    = "PRIVATE"
        e.location    = "#{place_name}, #{address}"
        e.url         = url
        e.created     = event.created_at
        e.last_modified = event.updated_at
        e.organizer   = author
        e.rrule       = "FREQ=WEEKLY;UNTIL=#{event.last_day.strftime("%Y%m%d")}"
        e.image       = image
      end

    end

    cal.publish
    cal.to_ical
  end

  def save_ical
    FileUtils.mkdir_p(File.dirname(saved_ical_file)) unless File.exist?(saved_ical_file)

    File.open(saved_ical_file, 'w') do |file|
      file.write(to_ical)
    end

    nil
  end

  def save_data
    FileUtils.mkdir_p(File.dirname(saved_data_file)) unless File.exist?(saved_data_file)

    file_contents = JSON.pretty_generate(events)

    File.open(saved_data_file, 'w') do |file|
      file.write(file_contents)
    end

    nil
  end

  def load_data
    return CalendarEventList.new() unless File.exist?(saved_data_file)

    file_contents = File.read(saved_data_file)
    return CalendarEventList.new() if file_contents.empty?

    loaded_events = JSON.parse(file_contents).map do |event|
      CalendarEvent.from_json(event)
    end

    CalendarEventList.new(loaded_events).sort!
  end

  private

  def saved_data_file
    @saved_data_file ||= File.join(File.dirname(__FILE__), 'data', "#{@place}.#{@language}.json")
  end

  def saved_ical_file
    @saved_ical_file ||= File.join(File.dirname(__FILE__), 'calendars', "#{@place}.#{@language}.ics")
  end

  def weekdays_map
    @weekdays_map ||= begin
      weekdays_map = {
        "lundi" => "monday",
        "mardi" => "tuesday",
        "mercredi" => "wednesday",
        "jeudi" => "thursday",
        "vendredi" => "friday",
        "samedi" => "saturday",
        "dimanche" => "sunday",
      }
      weekdays_map.default_proc = Proc.new { |hash, key| key }

      weekdays_map
    end
  end

  def browser
    @browser ||= Mechanize.new
  end

  def page
    @page ||= browser.get(url)
  end

  def message_bar
    @message_bar ||= page.at('div.alert div.message-bar-container')
  end

  def contents
    @contents ||= page.at('div.content-modules')
  end

  def season_dates
    @season_dates ||= begin
      season_from, season_to = contents.search('time').map do |time|
        DateTime.parse(time.attributes['datetime'].value)
      end
      {
        from: season_from,
        to: season_to,
      }
    end
  end

  def scrapped_events
    @scrapped_events ||= begin
      events = []

      contents.search('div.wrapper-body div.content-module-stacked').each do |section|
        section_header = section.at('h3').text.strip

        section.at('tbody').search('tr').each do |row|
          day, hours = row.search('td')
          day = DateTime.parse(day.text.strip.downcase.gsub(/^.*$/, weekdays_map))

          hour_start, hour_end = hours.search('span').map(&:text).map(&:strip).map do |hour|
            DateTime.parse(hour)
          end

          weekday = day.strftime('%w').to_i

          from_time = hour_start.strftime('%H:%M').split(':').map(&:to_i)
          to_time = hour_end.strftime('%H:%M').split(':').map(&:to_i)

          events.push(CalendarEvent.new(self, weekday, from_time, to_time, section_header))
        end
      end

      events.sort
    end
  end

end


quintal = MontrealPlace.new('piscine-quintal', 'en')
quintal.update
