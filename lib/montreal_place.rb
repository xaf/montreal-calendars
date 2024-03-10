require 'fileutils'
require 'icalendar'
require 'icalendar/tzinfo'
require 'json'
require 'mechanize'

require_relative 'calendar_event'
require_relative 'calendar_event_list'

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
      # puts JSON.pretty_generate(scrapped_events)
      # raise "BLAH"
      events.upsert_all(scrapped_events)
      events
    end
  end

  def to_ical
    cal = Icalendar::Calendar.new
    cal.prodid = "-//#{place_name} (github.com/XaF/montreal-calendars)//iCal 2.0//EN"

    cal.x_wr_calname = place_name
    cal.x_wr_timezone = timezone_id
    cal.x_wr_caldesc = place_name
    cal.x_wr_calurl = url
    cal.x_wr_relcalid = "montreal-#{@place}-#{@language}"
    cal.x_wr_relscale = "GREGORIAN"
    cal.x_wr_calicon = image
    cal.x_wr_calctz = timezone_id
    cal.x_wr_calbase = url
    cal.x_wr_calaccess = "PUBLIC"
    cal.x_wr_calowner = author
    cal.x_wr_calscale = "GREGORIAN"
    cal.x_wr_calclass = "PUBLIC"
    cal.x_wr_calcolor = "#9fc6e7"

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

        if event.notice
          e.summary = "#{event.notice} - #{e.summary}"
          e.description = "#{event.notice} - #{event.notice_details}"
          e.color = "#f9c25c"
        else
          e.color = "#9fc6e7"
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
    @saved_data_file ||= File.join(Dir.pwd, 'data', "#{@place}.#{@language}.json")
  end

  def saved_ical_file
    @saved_ical_file ||= File.join(Dir.pwd, 'calendars', "#{@place}.#{@language}.ics")
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
      periods = []

      contents.search('div.wrapper-complex').each do |period|
        period_header = period.at('div.wrapper-header').at('div')

        times = period_header.search('time')
        period_start = DateTime.parse(times[0].attributes['datetime'].value)
        period_end = DateTime.parse(times[1].attributes['datetime'].value) + 1

        # puts "Found period from #{period_start} to #{period_end}"
        period_data = {
          start: period_start,
          end: period_end,
          events: []
        }

        period.search('div.wrapper-body div.content-module-stacked').each do |section|
          section_header = section.at('h3').text.strip
          # puts "Found section #{section_header}"

          section.at('tbody').search('tr').each do |row|
            day, hours = row.search('td')
            day = DateTime.parse(day.text.strip.downcase.gsub(/^.*$/, weekdays_map))

            hour_start, hour_end = hours.search('span').map(&:text).map(&:strip).map do |hour|
              DateTime.parse(hour)
            end

            weekday = day.strftime('%w').to_i

            from_time = hour_start.strftime('%H:%M').split(':').map(&:to_i)
            to_time = hour_end.strftime('%H:%M').split(':').map(&:to_i)

            event = CalendarEvent.new(self, weekday, from_time, to_time, section_header, true)
            # event.set_period(period_start, period_end)

            period_data[:events].push(event)
          end
        end

        periods.push(period_data)
      end

      # Prepare final list of events
      events = []

      # Sort periods by period_start
      periods.sort_by! { |period| period[:start] }

      # While periods is not empty
      while !periods.empty?
        # Take the first period
        period = periods.shift

        # Check if we need to override the period end of the events
        if periods.first && periods.first[:start] < period[:end]
          if periods.first[:end] < period[:end]
            periods.push({
              start: periods.first[:end],
              end: period[:end],
              events: period[:events].map { |event| event.clone },
            })
          end

          # Override the period end of the events
          period[:end] = periods.first[:start]

          # Skip the period if it is empty
          next if period[:end] <= period[:start]
        end

        # puts "Period from #{period[:start]} to #{period[:end]}"

        # For each event in the period
        period[:events].each do |event|
          event.set_period(period[:start], period[:end])
          events.push(event)
          # puts "Event #{event.desc} from #{event.first_day} to #{event.last_day}"
        end
      end

      events.sort
    end
  end
end

