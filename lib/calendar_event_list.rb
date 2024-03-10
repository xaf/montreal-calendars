

class CalendarEventList < Array
  def upsert_all(events)
    events.each do |event|
      upsert(event, false)
    end

    end_unseen!
    cleanup!
  end

  def upsert(event, cleanup=true)
    index = self.rindex do |e|
      e.static_hash == event.static_hash
    end

    unless index.nil?
      match = self[index]
      match.seen!
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
    cleanup! if cleanup
  end

  def new_or_updated?(event)
    index = self.rindex do |e|
      e.static_hash == event.static_hash
    end

    return true if index.nil?

    match = self[index]
    event.dynamic_hash != match.dynamic_hash
  end

  def expire_date
    @expire_date ||= begin
      date = DateTime.now
      DateTime.new(date.year - 2, date.month, date.day, date.hour, date.minute, date.second)
    end
  end

  def end_unseen!
    self.select { |event| !event.seen? && event.last_day > DateTime.now }.each do |event|
      event.end_after(DateTime.now)
    end
  end

  def cleanup!
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

