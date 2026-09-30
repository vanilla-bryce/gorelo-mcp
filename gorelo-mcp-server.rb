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
#   GORELO_ALLOW_WRITES  "true" enables the six write tools. Default off.
#   GORELO_DOWNLOAD_DIR  where invoice PDFs are saved. Default ~/gorelo-invoices
#   GORELO_ATTACH_DIR    the ONLY folder comment attachments come from.
#                        Default ~/gorelo-attachments
#
# stdout is the MCP transport. Diagnostics go to stderr, always.

require_relative 'lib/mcp_server'
require_relative 'lib/gorelo'
require_relative 'lib/gorelo_tools'
require_relative 'lib/gorelo_billing_tools'
require_relative 'lib/gorelo_uptime_tools'
require_relative 'lib/gorelo_time_entry_tools'

VERSION = '1.1.0'

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

    TIME. Since Gorelo's 2026-09-04 release, GET /v1/time-entries returns one row per
    logged entry with the user who logged it, so per-technician hours from
    gorelo_time_report are EXACT - not attributed to a ticket's lead assignee, as they
    were before. Whether an hour can be invoiced is decided by the entry's own
    BillableStatus; never re-derive it from the work type or the contract.

    CONTRACTS, and the wording is inverted from Gorelo's own web UI. An API "contract"
    (gorelo_list_contracts) is what the UI calls a CONTRACT GROUP - the invoice - and an
    API "ServiceLine" is what the UI calls a CONTRACT. Say both when reporting one, or
    the user will compare it to their screen and conclude the data is wrong.

    INVOICES created here are ALWAYS Drafts; approving one pushes it to the accounting
    system and is left to a person in Gorelo. Downloading an invoice PDF is recorded by
    Gorelo as an export event on that invoice, so do not download one just to read it.

    Six tools write - gorelo_add_ticket_comment, gorelo_update_ticket,
    gorelo_set_uptime_maintenance, gorelo_create_draft_invoice, gorelo_update_time_entry
    and gorelo_update_time_entries - and all are off unless explicitly enabled. Nothing
    here can delete anything.

    RECODING TIME. gorelo_update_time_entry (and its batch form) changes only a time entry's
    work type, billable status, service line and comment - never hours, dates, technician or
    ticket. Without confirm: true it only previews. Gorelo RE-PRICES an entry whenever work
    type, billable status or service line changes and moves contract hours between contracts,
    so always show the preview to the person and get their approval before confirming.
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
GoreloBillingTools.register(server, api)
GoreloUptimeTools.register(server, api)
GoreloTimeEntryTools.register(server, api)
server.run
