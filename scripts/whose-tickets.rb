#!/usr/bin/env ruby
# frozen_string_literal: true

# Why does Gorelo's UI show more tickets assigned to you than the API does?
#
# Gorelo exposes exactly one assignment filter - LeadAssigneeIds. There is no
# server-side filter for assisting assignees or watchers (AssistingAssigneeIds,
# AssigneeIds, AssistingAssigneeId and WatcherIds are all silently ignored -
# they return the full unfiltered set, with the no-filter FilterHash).
#
# So the only way to find tickets you are on but do not lead is to page the
# whole ticket table once and look. That is what this does.
#
#   ruby scripts/whose-tickets.rb
#
# Read-only. Takes a couple of minutes.

require_relative '../lib/gorelo'
require_relative '../lib/gorelo_tools'

def load_dotenv(path)
  return unless File.exist?(path)

  File.foreach(path) do |line|
    line = line.strip
    next if line.empty? || line.start_with?('#')

    key, _, value = line.partition('=')
    key = key.strip.sub(/\Aexport\s+/, '')
    next if key.empty?

    value = value.strip
    value = value[1..-2] if value.length > 1 && (value[0] == value[-1]) && %w[" '].include?(value[0])
    ENV[key] ||= value
  end
end

load_dotenv(File.join(__dir__, '..', '.env'))

api = Gorelo::Client.new(
  api_key:  ENV['GORELO_API_KEY'],
  base_url: ENV['GORELO_BASE_URL'] || 'https://api.aue.gorelo.io',
  logger:   ->(m) { warn "  #{m}" }
)

me = api.resolve_user_id(ENV['MY_ID'] || 'me').to_s
warn "Scanning every ticket for user #{me}. This pages the whole table once."

all = api.get_all('/v1/tickets')
warn "#{all.size} tickets scanned.\n\n"

def ids(ticket, field)
  Array(ticket[field]).map(&:to_s)
end

lead = []
assisting = []
watching = []

all.each do |t|
  status_id = GoreloTools.nested(t, 'Status', 'Id')
  next if status_id.to_s == '4'          # Closed
  next if GoreloTools.merged?(t)         # Merged - a duplicate of another ticket

  if t['LeadAssigneeId'].to_s == me
    lead << t
  elsif ids(t, 'AssistingAssigneeIds').include?(me)
    assisting << t
  elsif ids(t, 'WatcherIds').include?(me)
    watching << t
  end
end

puts '=' * 96
puts 'UNCLOSED TICKETS YOU ARE ATTACHED TO (merged and closed excluded)'
puts '=' * 96
puts format('  %-22s %4d   <- what gorelo_list_tickets reports', 'Lead assignee', lead.size)
puts format('  %-22s %4d', 'Assisting assignee', assisting.size)
puts format('  %-22s %4d', 'Watcher only', watching.size)
puts format('  %-22s %4d   <- compare against the number in the Gorelo UI',
            'TOTAL', lead.size + assisting.size + watching.size)
puts

[['ASSISTING ASSIGNEE - not lead', assisting],
 ['WATCHER ONLY', watching]].each do |title, rows|
  next if rows.empty?

  puts '-' * 96
  puts title
  puts '-' * 96
  rows.sort_by { |t| -(GoreloTools.days_since(t['UpdatedOn']) || 0) }.each do |t|
    puts format('  %-9s %-22s %-26s %s idle  %s',
                t['DisplayNumber'] || "G-#{t['Number']}",
                GoreloTools.clip(GoreloTools.nested(t, 'Status', 'Name'), 22),
                GoreloTools.clip(api.client_name(t['ClientId']) || t['ClientId'], 26),
                GoreloTools.age(t['UpdatedOn']),
                GoreloTools.clip(t['Title'], 55))
  end
  puts
end

if assisting.empty? && watching.empty?
  puts 'Nothing. Every unclosed ticket you are attached to, you lead - so the'
  puts 'difference against the UI is something else, and worth a second look.'
end
