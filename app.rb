#!/usr/bin/env ruby

require 'yaml'
require_relative 'lib/montreal_place'

languages = []
places = []

File.open('config.yaml', 'r') do |file|
  config = YAML.load(file)

  languages = config['languages']
  places = config['places']
end

raise "No languages defined" if languages.empty?
raise "No places defined" if places.empty?

errors = 0
places.each do |place|
  languages.each do |language|
    puts("Updating #{place} (#{language})...")
    MontrealPlace.new(place, language).update
  rescue => e
    STDERR.puts("Error while updating #{place} (#{language}): #{e}")
    errors += 1
  end
end

raise "Errors while updating" if errors > 0
