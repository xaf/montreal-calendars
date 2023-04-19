require 'date'
require 'fileutils'
require 'icalendar'
require 'icalendar/tzinfo'
require 'json'
require 'mechanize'

require_relative 'calendar_event'
require_relative 'calendar_event_list'
require_relative 'utils'


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

      events.each do |event|
        debug("Loading event: #{event.desc.light_cyan.italic}")
      end

      events.upsert_all(scrapped_events)

      events.each do |event|
        debug("Final events: #{event.desc.light_blue.italic}")
      end

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

    earliest_date = events.min_by(&:start_datetime).start_datetime

    tz = TZInfo::Timezone.get(timezone_id)
    timezone = tz.ical_timezone(earliest_date)
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

    # Load the ical first in case there is an issue generating it, so
    # we don't overwrite the existing file
    file_contents = to_ical

    File.open(saved_ical_file, 'w') do |file|
      file.write(file_contents)
    end

    nil
  end

  def save_data
    FileUtils.mkdir_p(File.dirname(saved_data_file)) unless File.exist?(saved_data_file)

    # Load the data first in case there is an issue generating it, so
    # we don't overwrite the existing file
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

    CalendarEventList.new(loaded_events)
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
    # @page ||= browser.get(url)
    # @page ||= browser.get("file:///#{Dir.pwd}/doc-bibliotheque-cote-des-neiges.html")
    @page ||= browser.get("file:///#{Dir.pwd}/doc-bibliotheque-frontenac.html")
  end

  def message_bar
    @message_bar ||= page.at('div.alert div.message-bar-container')
  end

  def contents
    @contents ||= page.at('div.content-modules')
  end

  def sidebar
    @sidebar ||= page.at('div.sidebar')
  end

  def season_dates
    @season_dates ||= begin
      season_from, season_to = contents.search('time').map do |time|
        Date.parse(time.attributes['datetime'].value)
      end
      {
        from: season_from,
        to: season_to,
      }
    end
  end

  def scrapped_events
    @scrapped_events ||= begin
      events = CalendarEventList.new

      contents.search('div.wrapper-body div.content-module-stacked').each do |section|
        section_header = section.at('h3').text.strip

        section.at('tbody').search('tr').each do |row|
          day, hours = row.search('td')
          day = Date.parse(day.text.strip.downcase.gsub(/^.*$/, weekdays_map))

          hour_start, hour_end = hours.search('span').map(&:text).map(&:strip).map do |hour|
            DateTime.parse(hour)
          end

          weekday = day.strftime('%w').to_i

          from_time = hour_start.strftime('%H:%M').split(':').map(&:to_i)
          to_time = hour_end.strftime('%H:%M').split(':').map(&:to_i)

          events.push(CalendarEvent.new(self, weekday, from_time, to_time, section_header))
        end
      end

      if events.empty?
        section_title = nil
        opening_hours_block = sidebar.search('section.sb-block').find do |section|
          section_title = section.at('h2.sidebar-title').text.strip
          ["Heures d'ouverture", "Opening hours"].include?(section_title)
        end

        event_groups = {}

        opening_hours_block.search('div.list-item-icon-content').each do |schedule|
          section_header = schedule.at('div.list-item-icon-label').text.strip

          period_start = period_end = nil
          second_div = schedule.search('div').to_a[1].text.strip
          if second_div =~ /^(From|Du) .* (to|au)/i
            period_start, period_end = second_div.
              gsub(/^Du /i, 'From ').
              gsub(/ au /i, ' to ').
              gsub(/^From ([0-9]+) to ([0-9]+) ([^0-9\-_,]+ [0-9]{4})$/i, '\1 \3 to \2 \3').
              gsub(/^From /, '').
              split(' to ').
              map do |d|
                day, month, year = d.split(' ')
                month = month[..3].downcase.gsub('é', 'e')
                Date.parse("#{day} #{month}. #{year}")
              end
          end

          groupid = if ["Horaire", "Schedule"].include?(section_header)
            'default'
          elsif period_start && period_end
            "#{section_header} #{period_start} #{period_end}"
          else
            section_header
          end
          event_groups[groupid] ||= CalendarEventList.new

          # second_div.split(' ').each_cons(3).find do |txtblk|
            # next unless txtblk.any? { |t| t =~ /\d/ }

            # s = txtblk.join(' ')
            # puts "S: #{s}"
            # begin
              # d = Date.parse(s)
              # puts "D: #{d}"
            # rescue
              # nil
            # end
          # end

          schedule.search('ul.list-unstyled li.row').each do |row|
            day = row.at('span.schedule-day').text.strip
            day = Date.parse(day.downcase.gsub(/^.*$/, weekdays_map))

            hour_start, hour_end = row.at('div.schedule-data').search('span').map(&:text).map(&:strip).map do |hour|
              DateTime.parse(hour)
            end

            next unless day && hour_start && hour_end

            weekday = day.strftime('%w').to_i

            from_time = hour_start.strftime('%H:%M').split(':').map(&:to_i)
            to_time = hour_end.strftime('%H:%M').split(':').map(&:to_i)

            if period_start.nil? && period_end.nil?
              # No beginning nor end, so we'll make it start at the beginning of
              # last year and end at the end of next year.
              period_start = Date.new(Date.today.year - 1, 1, 1)
              period_end = Date.new(Date.today.year + 1, 12, 31)
            end

            title = section_title
            title = "#{title} (#{section_header})" unless groupid == 'default'

            event = CalendarEvent.new(
              self, weekday, from_time, to_time, section_header,
              period_start: period_start,
              period_end: period_end,
              title: title,
            )

            event_groups[groupid].push(event)
          end
        end

        # Use the default group as base, then override it with the
        # other groups' data (if any).
        events = event_groups.delete('default')
        event_groups.each do |_groupid, group|
          events.override(group, use_period: true)
        end
      end

      raise "No events found" if events.empty?

      events.each do |event|
        event.seen!
        debug("Scrapped event: #{event.desc.cyan}")
      end

      events
    end
  end
end

