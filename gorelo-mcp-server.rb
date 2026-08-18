#!/usr/bin/env ruby
# frozen_string_literal: true

# AMIT Gorelo MCP server - local stdio transport, zero gem dependencies.
#
#   ruby gorelo-mcp-server.rb
#
# Reads configuration from .env beside this file, or from the environment:
#
#   GORELO_API_KEY       required
#   GORELO_MY_EMAIL      required for assignee "me"
#   GORELO_BASE_URL      default https://api.aue.gorelo.io
#   GORELO_ALLOW_WRITES  "true" enables the single write tool. Default off.
#
# stdout is the MCP transport. Diagnostics go to stderr, always.

require_relative 'lib/mcp_server'
require_relative 'lib/gorelo'
require_relative 'lib/gorelo_tools'

VERSION = '1.0.0'

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

load_dotenv(File.join(__dir__, '.env'))

server = McpStdio::Server.new(
  name:    'gorelo',
  version: VERSION,
  instructions: <<~TEXT
    Gorelo PSA. Read-mostly.

    Ticket status is filtered on BaseStatusId, not status name. Gorelo files custom
    statuses such as "Standing Ticket" and "Billing" under the SOLVED base, so those
    are real outstanding work and are NOT closed. When counting a backlog, use
    status "open" (active + solved base) rather than "active".

    Only gorelo_add_ticket_comment writes, and it is off unless explicitly enabled.
  TEXT
)

begin
  api = Gorelo::Client.new(
    api_key:      ENV['GORELO_API_KEY'],
    base_url:     ENV['GORELO_BASE_URL'] || 'https://api.aue.gorelo.io',
    allow_writes: ENV['GORELO_ALLOW_WRITES'].to_s.downcase == 'true',
    logger:       ->(m) { server.log(m) }
  )
rescue Gorelo::Error => e
  warn "[gorelo-mcp] FATAL: #{e.message}"
  warn '[gorelo-mcp] Create a .env beside this script with GORELO_API_KEY=...'
  exit 1
end

server.log("base_url=#{api.base_url} writes=#{api.writes_allowed? ? 'ENABLED' : 'disabled'}")

GoreloTools.register(server, api)
server.run
