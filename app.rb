#!/usr/bin/env ruby

require 'mechanize'
require 'icalendar'
require 'icalendar/tzinfo'

class MontrealPlace
  def initialize(place, language='fr')
    @place = place.downcase
    @language = language.downcase
  end

  def url
    @url ||= if @language == 'en'
      "https://montreal.ca/en/places/#{@place}"
    else
      "https://montreal.ca/lieux/#{@place}"
    end
  end

  def calendar
    @calendar ||= begin
      calendar ={}

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

          # first_day = season_from + (weekday - season_from.wday) % 7
          # event_start = DateTime.new(first_day.year, first_day.month, first_day.day, from_time[0], from_time[1], 0)
          # event_end = DateTime.new(first_day.year, first_day.month, first_day.day, to_time[0], to_time[1], 0)

          calendar[weekday] ||= []
          calendar[weekday].push({
            from: from_time,
            to: to_time,
            section: section_header,
          })
        end
      end

      calendar
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

  private

  def saved_data_file
    @saved_data_file ||= File.join(File.dirname(__FILE__), 'data', @language, "#{@place}.json")
  end

  def load_saved_data
    @saved_data ||= begin
      if File.exists?(saved_data_file)
        JSON.parse(File.read(saved_data_file))
      else
        {}
      end
    end
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
end


quintal = MontrealPlace.new('piscine-quintal', 'en')

# exit

cal = Icalendar::Calendar.new

tz = TZInfo::Timezone.get(quintal.timezone_id)
timezone = tz.ical_timezone(quintal.season_from)
cal.add_timezone(timezone)

# Find the first date for each day of the week
quintal.calendar.sort.each do |day, periods|
  periods.sort_by { |period| [period[:from], period[:to]] }.each do |period|

    first_day = quintal.season_from + (day - quintal.season_from.wday) % 7

    event_start = DateTime.new(first_day.year, first_day.month, first_day.day, period[:from][0], period[:from][1], 0)
    event_end = DateTime.new(first_day.year, first_day.month, first_day.day, period[:to][0], period[:to][1], 0)

    cal.event do |e|
      # e.uid         = 'blah'
      e.dtstart     = Icalendar::Values::DateTime.new(event_start, 'tzid' => quintal.timezone_id)
      e.dtend       = Icalendar::Values::DateTime.new(event_end, 'tzid' => quintal.timezone_id)
      e.summary     = "#{quintal.event_title} #{period[:section].downcase}"

      if quintal.notice
        e.summary = "#{quintal.notice} - #{e.summary}"
        e.description = "#{quintal.notice} - #{quintal.notice_details}"
        e.color = "#ffb833"
      else
        e.color = "#00a0e9"
      end

      # e.ip_class    = "PRIVATE"
      e.location    = "#{quintal.place_name}, #{quintal.address}"
      e.url         = quintal.url
      e.created     = DateTime.now
      e.last_modified = DateTime.now
      e.organizer   = quintal.author
      e.rrule       = "FREQ=WEEKLY;UNTIL=#{quintal.season_to.strftime('%Y%m%d')}"
      e.image       = quintal.image
    end

  end
end

cal.publish
puts cal.to_ical
