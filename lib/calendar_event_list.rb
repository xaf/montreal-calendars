require 'colorize'
require 'date'

require_relative 'calendar_event'
require_relative 'utils'


class CalendarEventList < Array
  def self.new(*args, **kwargs)
    obj = super(*args, **kwargs)

    obj.cleanup
    obj.sort!

    obj
  end

  def upsert_all(events)
    events.each do |event|
      upsert(event, false)
    end

    end_unseen
    cleanup
  end

  def upsert(event, cleanup=true)
    index = self.rindex do |e|
      e.static_hash == event.static_hash && e.overlap(event)
    end

    unless index.nil?
      debug("MATCHED #{event.desc.cyan} "\
          "\n          sta: #{event.static_hash.yellow}"\
          "\n          dyn: #{event.dynamic_hash.light_yellow}"\
          "\n   with #{self[index].desc.light_cyan} "\
          "\n          sta: #{self[index].static_hash.yellow}"\
          "\n          dyn: #{self[index].dynamic_hash.light_yellow}")

      match = self[index]
      if event.dynamic_hash == match.dynamic_hash
        debug("     => No change; updating last day; marking as seen".green.bold)

        match.instance_variable_set(:@last_day, event.last_day)
        match.seen!
        return
      end

      debug("     => Ending saved event, starting new event".light_magenta.bold)

      now = DateTime.now
      match.end_before(now)
      event.start_after(now)
    end

    push(event)
    cleanup if cleanup
  end

  def push(*args, **kwargs)
    ret = super(*args, **kwargs)

    cleanup
    sort!

    ret
  end

  def end_unseen
    now = DateTime.now

    select { |event| !event.seen? && event.last_day > now }
      .each { |event| event.end_before(now) }
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
    sort!
  end

  def period_start
    map(&:period_start).min
  end

  def period_end
    map(&:period_end).max
  end

  def start_date
    map(&:first_day).min
  end

  def end_date
    map(&:last_day).max
  end

  def override(calendar_event_list, use_period: false)
    # Get the dates of the period to override
    if use_period
      override_start = calendar_event_list.period_start
      override_end = calendar_event_list.period_end
    else
      override_start = calendar_event_list.start_date
      override_end = calendar_event_list.end_date
    end

    new_events = self.map do |event|
      event.without_period(override_start, override_end + 1)
    end.flatten

    clear

    concat(new_events)
    concat(calendar_event_list)

    cleanup
    sort!

    self
  end
end

