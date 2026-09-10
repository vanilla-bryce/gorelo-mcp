# frozen_string_literal: true

# Tool definitions. Deliberately free of any MCP-library types so this file
# survives a swap of the transport layer underneath it.
#
# Two principles run through every tool here:
#
#   1. Return prose a human could read, not raw JSON. The model reads these
#      results into a finite context window; a 40-field PascalCase object per
#      ticket buys nothing over eight useful columns.
#   2. Never filter something out silently. A backlog that quietly reports a
#      smaller number than it holds is worse than no tool at all, so counts
#      are always stated and anything excluded is named.

require 'time'
require 'set'
require 'json'
require_relative 'gorelo'

module GoreloTools
  module_function

  # ---- formatting helpers -------------------------------------------------

  def days_since(value)
    return nil if value.nil? || value.to_s.empty?

    ((Time.now.utc - Time.parse(value.to_s).utc) / 86_400).floor
  rescue ArgumentError
    nil
  end

  def age(value)
    d = days_since(value)
    d.nil? ? '   -' : format('%4dd', d)
  end

  def clip(text, width)
    s = text.to_s.gsub(/\s+/, ' ').strip
    s.length > width ? "#{s[0, width - 1]}…" : s
  end

  # Always leaves at least one space after the value, so a full-width cell
  # cannot run into the next column.
  def pad(text, width)
    clip(text, width - 1).ljust(width)
  end

  # "Merged" is a STATUS in Gorelo (id 5), not the IsMerged flag - which is
  # false even on merged tickets. Filtering on the flag alone leaves merged
  # tickets sitting in the backlog looking like live work.
  def merged?(ticket)
    ticket['IsMerged'] == true ||
      nested(ticket, 'Status', 'Name').to_s.strip.casecmp?('merged')
  end

  # Gorelo stores StatusReason as a JSON blob, not a string:
  #   {"reason":"waiting on the replacement part","updatedById":42,...}
  # Statuses with AskForReason set - On Hold, Scheduled, Waiting Client,
  # Waiting 3rd Party and Billing - all collect one, which makes it the single
  # most useful field on a stalled ticket: it says why it stopped.
  def status_reason(ticket)
    raw = ticket['StatusReason'].to_s.strip
    return nil if raw.empty?

    if raw.start_with?('{')
      parsed = begin
        JSON.parse(raw)
      rescue JSON::ParserError
        nil
      end
      return parsed['reason'].to_s.strip if parsed.is_a?(Hash) && !parsed['reason'].to_s.strip.empty?
    end
    raw
  end

  def nested(hash, *keys)
    keys.reduce(hash) { |acc, k| acc.is_a?(Hash) ? acc[k] : nil }
  end

  # ---- registration -------------------------------------------------------

  def register(server, api)
    list_tickets(server, api)
    get_ticket(server, api)
    search_clients(server, api)
    get_client(server, api)
    get_contact(server, api)
    list_assets(server, api)
    billing_review(server, api)
    time_report(server, api)
    response_report(server, api)
    add_ticket_comment(server, api)
    update_ticket(server, api)
    api_probe(server, api)
  end

  # ---- 1. list tickets ----------------------------------------------------

  def list_tickets(server, api)
    server.tool(
      name:  'gorelo_list_tickets',
      title: 'List Gorelo tickets',
      description: <<~TEXT,
        List tickets from Gorelo with filtering. Defaults to active tickets assigned to you.

        Status filtering happens locally on BaseStatusId, never server-side, because Gorelo
        files custom statuses such as "Standing Ticket" and "Billing" under the SOLVED base -
        filtering on the server hides real work without saying so.

          active  New + Open + On Hold                    (the default)
          solved  the solved base, incl. Standing/Billing (real work lives here)
          closed  genuinely closed
          open    everything except closed
          all     everything

        Assignment matches what Gorelo's own UI counts: tickets where you are the LEAD or the
        ASSISTING assignee, but not ones where you are only a watcher. Gorelo has no
        assisting-assignee filter, so those are found with one extra sweep of the
        organisation's unclosed tickets - normally a single page, one request.

        The reply always states the full unfiltered count so nothing disappears quietly.
      TEXT
      input_schema: {
        type: 'object',
        properties: {
          assignee:   { type: 'string', description: 'Gorelo user id, email, name fragment, or "me". Use "anyone" for no assignee filter. Default "me".' },
          status:     { type: 'string', enum: %w[active solved closed open all], description: 'Default "active".' },
          client:     { type: 'string', description: 'Client name fragment or id. Comma-separate several terms.' },
          search:     { type: 'string', description: 'Keyword matched by Gorelo against the ticket title, number and display number.' },
          stale_days: { type: 'integer', description: 'Only tickets not updated for at least this many days.' },
          include_reasons: { type: 'boolean', description: 'Show the status reason under each row. Gorelo collects one whenever a ticket moves to Billing, On Hold, Scheduled or either Waiting status - it is usually the note saying what still has to happen.' },
          include_assisting: { type: 'boolean', description: 'Also include unclosed tickets where you are an assisting assignee, matching what the Gorelo UI counts. Default true. Costs one extra request.' },
          limit:      { type: 'integer', description: 'Max rows to display. Default 40.' }
        },
        additionalProperties: false
      }
    ) do |args|
      status  = (args['status'] || 'active').downcase
      limit   = (args['limit'] || 40).to_i.clamp(1, 300)
      query   = { 'SortBy' => 'updatedOn', 'SortOrder' => 'desc' }
      scope   = []

      assignee = args['assignee'] || 'me'
      uid = nil
      unless assignee.to_s.downcase == 'anyone'
        uid = api.resolve_user_id(assignee)
        query['LeadAssigneeIds'] = uid.to_s
        scope << "assignee=#{assignee}"
      end

      if args['search'] && !args['search'].to_s.empty?
        # Documented server-side search. Matches title, number and display
        # number; capped at 200 characters by the API.
        query['Query'] = args['search'].to_s[0, 200]
        scope << "search=#{args['search']}"
      end

      if args['client'] && !args['client'].to_s.empty?
        matched = api.resolve_clients(args['client'])
        raise Gorelo::Error, "No client matches #{args['client'].inspect}" if matched.empty?

        query['ClientIds'] = matched.map { |c| c['Id'] }.join(',')
        scope << "client=#{matched.map { |c| c['Name'] }.join(' + ')}"
      end

      if scope.empty?
        raise Gorelo::Error,
              'Refusing to page the entire ticket database. Give an assignee, a client, or both.'
      end

      rows = api.get_all('/v1/tickets', query)
      rows.each { |t| t['_role'] = 'lead' }

      # Gorelo's own "assigned to me" counts you as Lead OR Assisting. There is
      # no AssistingAssigneeIds filter - it, AssigneeIds, AssistingAssigneeId
      # and WatcherIds are all silently ignored, returning the unfiltered set.
      # So assisting tickets are found by sweeping every unclosed ticket in the
      # organisation, which is normally a single page and one request.
      assisting = 0
      if uid && args.fetch('include_assisting', true) && status != 'closed'
        seen = rows.map { |t| t['Id'] }.to_set
        sweep = api.get_all('/v1/tickets',
                            { 'StatusIds' => api.unclosed_status_ids.join(',') })
        sweep.each do |t|
          next if seen.include?(t['Id'])
          next unless Array(t['AssistingAssigneeIds']).map(&:to_s).include?(uid.to_s)

          t['_role'] = 'assist'
          rows << t
          assisting += 1
        end
      end

      total = rows.size

      buckets = Hash.new { |h, k| h[k] = [] }
      unknown = Hash.new(0)
      rows.each do |t|
        base = api.base_status_id(nested(t, 'Status', 'Id'))
        # A status Gorelo did not return from /v1/tickets/statuses is NOT
        # quietly assumed to be open. It is counted, named, and included, so
        # an unfamiliar status can never remove work from the list unseen.
        # Merged is itself an unlisted status in real Gorelo, and it is already
        # reported on its own line - counting it here too reads as a
        # contradiction ("14 shown" next to "14 excluded").
        unknown[nested(t, 'Status', 'Name') || 'unnamed'] += 1 if base.nil? && !merged?(t)
        buckets[base] << t
      end

      merged = rows.count { |t| merged?(t) }
      wanted =
        case status
        when 'active' then Gorelo::ACTIVE_BASES
        when 'solved' then [Gorelo::BASE_SOLVED]
        when 'closed' then [Gorelo::BASE_CLOSED]
        when 'open'   then Gorelo::ACTIVE_BASES + [Gorelo::BASE_SOLVED]
        else buckets.keys
        end

      selected = rows.select do |t|
        base = api.base_status_id(nested(t, 'Status', 'Id'))
        base.nil? ? status != 'closed' : wanted.include?(base)
      end
      selected.reject! { |t| merged?(t) }

      if args['stale_days']
        n = args['stale_days'].to_i
        selected.select! { |t| (days_since(t['UpdatedOn']) || 0) >= n }
      end

      selected.sort_by! { |t| -(days_since(t['UpdatedOn']) || 0) }

      out = []
      out << "#{total} tickets match #{scope.join(', ')} across every status" +
             (assisting.positive? ? " (#{total - assisting} as lead, #{assisting} as assisting assignee)." : '.')
      out << 'Breakdown by base status: ' +
             buckets.sort_by { |k, _| k.to_i }
                    .map { |base, v| "#{Gorelo::BASE_NAMES[base] || (base.nil? ? 'UNKNOWN' : "base #{base}")} #{v.size}" }
                    .join(' · ')
      unless unknown.empty?
        out << "⚠ #{unknown.values.sum} tickets carry a status Gorelo did not list in " \
               "/v1/tickets/statuses (#{unknown.map { |n, c| "#{n} ×#{c}" }.join(', ')}). " \
               'They are shown rather than dropped.'
      end
      out << "#{merged} merged tickets excluded - they are duplicates of other tickets." if merged.positive?
      out << ''
      out << "Showing #{[selected.size, limit].min} of #{selected.size} matching status=#{status}:"
      out << ''
      out << "#{pad('Ticket', 9)}#{pad('Role', 7)}#{pad('Status', 22)}#{pad('Client', 26)}  age  idle  Title"
      out << ('-' * 104)

      selected.first(limit).each do |t|
        out << [
          pad(t['DisplayNumber'] || "G-#{t['Number']}", 9),
          pad(t['_role'], 7),
          pad(nested(t, 'Status', 'Name'), 22),
          pad(api.client_name(t['ClientId']) || t['ClientId'], 26),
          age(t['CreatedOn']),
          age(t['UpdatedOn']),
          '  ',
          clip(t['Title'], 60)
        ].join
        if args['include_reasons'] && (reason = status_reason(t))
          out << "#{' ' * 18}\u21B3 #{clip(reason, 100)}"
        end
      end

      if selected.size > limit
        out << ''
        out << "#{selected.size - limit} more not shown - raise `limit` or narrow the filter."
      end

      out.join("\n")
    end
  end

  # ---- 2. get ticket ------------------------------------------------------

  # Gorelo has no lookup by number and no search - see Gorelo::Client#ticket_by_number,
  # which resolves the number to a GUID locally.
  def find_ticket(api, reference)
    raise Gorelo::Error, 'Give a ticket number such as G-13933, or a ticket id.' \
      if reference.to_s.strip.empty?

    api.ticket_by_number(reference)
  end

  def get_ticket(server, api)
    server.tool(
      name:  'gorelo_get_ticket',
      title: 'Get one Gorelo ticket',
      description: 'Full detail for a single ticket by number (G-13933) or id, including the ' \
                   'client, contact, SLA, and the conversation if the API exposes it.',
      input_schema: {
        type: 'object',
        properties: {
          ticket:           { type: 'string', description: 'Ticket number such as G-13933, or a ticket id.' },
          include_comments: { type: 'boolean', description: 'Fetch the conversation too. Default true.' },
          comment_limit: { type: 'integer', description: 'How many of the most recent comments to show. Default 12.' },
          comment_chars: { type: 'integer', description: 'Max characters per comment. Default 1500.' }
        },
        required: ['ticket'],
        additionalProperties: false
      }
    ) do |args|
      t = find_ticket(api, args['ticket'])
      unless t
        next "No ticket #{args['ticket']} found, after checking every unclosed ticket, every " \
             'ticket you lead, and then the whole table. Check the number.'
      end

      # find_ticket resolves a number through the LIST endpoint, and a list row
      # is deliberately thinner than the get-by-id: no Description, no Time, no
      # Products, no linked assets. Re-fetch by id so this tool always renders
      # the full record regardless of how the ticket was found.
      #
      # Best-effort: a tenant that has not had the 2026-08-21 update, or a
      # transient failure, must still produce the ticket rather than an error.
      if t['Id']
        begin
          detail = api.get("/v1/tickets/#{t['Id']}")['Data']
          t = t.merge(detail) if detail.is_a?(Hash)
        rescue Gorelo::Error => e
          api_log = "could not fetch the full ticket detail (#{e.message.lines.first.to_s.strip})"
          t['_detail_warning'] = api_log
        end
      end

      out = []
      out << "#{t['DisplayNumber'] || "G-#{t['Number']}"}  #{t['Title']}"
      out << ('=' * 78)
      base = api.base_status_id(nested(t, 'Status', 'Id'))
      out << "Status      #{nested(t, 'Status', 'Name')} (base: #{Gorelo::BASE_NAMES[base] || base})"
      if (reason = status_reason(t))
        out << "Reason      #{reason}"
      end
      out << "Client      #{api.client_name(t['ClientId']) || '?'} (id #{t['ClientId']})"
      out << "Priority    #{nested(t, 'Priority', 'Name')}"
      out << "Type        #{nested(t, 'Type', 'Name')}    Source: #{nested(t, 'Source', 'Name')}"
      out << "Created     #{t['CreatedOn']}  (#{days_since(t['CreatedOn'])} days ago)"
      out << "Updated     #{t['UpdatedOn']}  (#{days_since(t['UpdatedOn'])} days ago)"
      out << "In status   since #{t['StatusUpdatedOn']} (#{days_since(t['StatusUpdatedOn'])} days)"
      out << "Closed      #{t['ClosedOn']}" if t['ClosedOn']
      # Renamed from IsAwaitingClient in the 2026-08-21 API release. The old
      # name is still read so this works against a tenant on either version -
      # and because a renamed boolean fails SILENTLY: the flag simply never
      # shows, and nothing tells you the ticket is sitting with the client.
      if t['IsWaitingOnThem'] || t['IsAwaitingClient']
        out << 'Waiting on them: YES - Gorelo believes the ball is in their court'
      end
      out << "MERGED into #{t['MergedIntoTicketId']}" if t['IsMerged']
      out << "Last update #{nested(t, 'LastUpdate', 'UpdateType')}: #{nested(t, 'LastUpdate', 'Summary')}"
      out << "Ticket id   #{t['Id']}"

      # NEW in the 2026-08-21 release: GET /v1/tickets/{id} returns a time and
      # billing breakdown. Before it, nothing about time was reachable through
      # the API at all, and "was this ticket ever billed?" could only be
      # answered inside Gorelo's UI.
      #
      # The distinction that matters: ActualHours is what was recorded,
      # AdjustedHours is what will be invoiced. A ticket sitting in Billing with
      # ActualHours of 0 was never time-recorded - which is a different problem
      # from one with hours that simply have not been invoiced yet.
      out << "⚠ #{t['_detail_warning']}" if t['_detail_warning']

      if (time = t['Time'])
        actual   = time['ActualHours'].to_f
        adjusted = time['AdjustedHours'].to_f
        billable = nested(time, 'Breakdown', 'Billable', 'AdjustedHours').to_f
        nonbill  = nested(time, 'Breakdown', 'NotBillable', 'AdjustedHours').to_f +
                   nested(time, 'Breakdown', 'NotBillableHidden', 'AdjustedHours').to_f

        out << ''
        out << format('Time        %.2fh recorded, %.2fh to invoice  (billable %.2fh, ' \
                      'not billable %.2fh)', actual, adjusted, billable, nonbill)
        if actual.zero?
          out << '            ⚠ NO TIME RECORDED on this ticket.'
        elsif billable.zero? && adjusted.positive?
          out << '            ⚠ time recorded but NONE of it is billable.'
        end
        if (products = t['Products']) && products['Count'].to_i.positive?
          out << format('Products    %d line(s), %.2f', products['Count'].to_i,
                        products['TotalAmount'].to_f)
        end
        if (override = t['BillingOverride']) && override.values.any? { |v| !v.nil? }
          out << "Billing     override set: #{override.reject { |_, v| v.nil? }.inspect}"
        end
      end

      if args.fetch('include_comments', true)
        out << ''
        out << 'Conversation'
        out << ('-' * 78)
        # Confirmed schema of /v1/tickets/{id}/comments:
        #   BodyText / BodyHtml / BodyTruncated
        #   Author { Type: "User"|"Contact", Id, Name, Email }
        #   ConversationType { Id: 1 Public, 2 Private }
        #   Source, CreatedOn, Attachments
        # An empty array means the ticket genuinely has no comments - which is
        # different from the endpoint not existing, and must not read the same.
        rows = begin
          Array(api.get("/v1/tickets/#{t['Id']}/comments", { 'PageSize' => 100 })['Data'])
        rescue Gorelo::AuthError
          raise
        rescue Gorelo::Error => e
          out << "Could not read comments: #{e.message}"
          nil
        end

        if rows&.empty?
          out << 'No comments on this ticket.'
        elsif rows
          limit_c = (args['comment_limit'] || 12).to_i.clamp(1, 100)
          out << "#{rows.size} comment(s)#{rows.size > limit_c ? ", showing the last #{limit_c}" : ''}:"
          rows.last(limit_c).each do |c|
            # Gorelo's API returns comments that have been DELETED, with no way
            # to exclude them - IncludeDeleted is ignored, and as of Aug 2026
            # the payload carries no flag, while the web UI correctly shows
            # "This comment has been deleted". Reported to Gorelo. This looks
            # for a flag anyway, so the day one appears the body stops being
            # printed without anyone having to remember why.
            deleted = c.any? { |k, v| k.to_s.match?(/deleted/i) && v && v != false }
            if deleted
              out << ''
              out << "[#{c['CreatedOn']}] — comment deleted in Gorelo, body withheld"
              next
            end

            author  = nested(c, 'Author', 'Name') || nested(c, 'Author', 'Email') || 'unknown'
            kind    = nested(c, 'Author', 'Type')
            private_ = nested(c, 'ConversationType', 'Name').to_s.casecmp?('private')
            body    = c['BodyText'].to_s
            body    = c['BodyHtml'].to_s.gsub(%r{</p>|<br\s*/?>}i, "\n").gsub(/<[^>]+>/, ' ') if body.strip.empty?
            files   = Array(c['Attachments'])

            out << ''
            out << "[#{c['CreatedOn']}] #{author}#{kind ? " (#{kind})" : ''}" \
                   "#{private_ ? ' — PRIVATE' : ''}#{c['BodyTruncated'] ? ' — TRUNCATED by Gorelo' : ''}"
            out << "  #{files.size} attachment(s)" unless files.empty?
            out << body.gsub(/\n{3,}/, "\n\n").strip[0, (args['comment_chars'] || 1500).to_i]
          end
        end
      end

      out.join("\n")
    end
  end

  # ---- 3. search clients --------------------------------------------------

  def search_clients(server, api)
    server.tool(
      name:  'gorelo_search_clients',
      title: 'Search Gorelo clients',
      description: 'Find clients by name fragment or id. Comma-separate several terms - useful ' \
                   'when one account is known by names that share no substring.',
      input_schema: {
        type: 'object',
        properties: {
          term:  { type: 'string', description: 'Name fragment or id. Comma-separated terms are OR-ed. Omit to list all.' },
          limit: { type: 'integer', description: 'Default 50.' }
        },
        additionalProperties: false
      }
    ) do |args|
      limit   = (args['limit'] || 50).to_i.clamp(1, 500)
      matched = if args['term'].to_s.strip.empty?
                  api.clients
                else
                  api.resolve_clients(args['term'])
                end

      next "No client matches #{args['term'].inspect}. #{api.clients.size} clients in Gorelo." if matched.empty?

      out = ["#{matched.size} of #{api.clients.size} clients match:", '']
      out << "#{pad('Id', 8)}#{pad('Name', 42)}Status"
      out << ('-' * 68)
      matched.first(limit).each do |c|
        out << "#{pad(c['Id'], 8)}#{pad(c['Name'] || c['CompanyName'], 42)}" \
               "#{c['IsActive'].nil? ? (nested(c, 'Status', 'Name') || '') : (c['IsActive'] ? 'Active' : 'Inactive')}"
      end
      out << "#{matched.size - limit} more not shown." if matched.size > limit
      out.join("\n")
    end
  end

  # ---- 4. get client ------------------------------------------------------

  def get_client(server, api)
    server.tool(
      name:  'gorelo_get_client',
      title: 'Get a Gorelo client footprint',
      description: 'One client: their details, active ticket counts, contacts, and managed devices. ' \
                   'This is the "what do we actually have with this client" view.',
      input_schema: {
        type: 'object',
        properties: {
          client:          { type: 'string', description: 'Client name fragment or id. Comma-separate several terms.' },
          include_devices: { type: 'boolean', description: 'Include the device list. Default true. The agents endpoint has no client filter, so this pages the whole fleet once.' }
        },
        required: ['client'],
        additionalProperties: false
      }
    ) do |args|
      matched = api.resolve_clients(args['client'])
      next "No client matches #{args['client'].inspect}." if matched.empty?

      ids = matched.map { |c| c['Id'] }
      out = []
      matched.each { |c| out << "#{c['Id']}  #{c['Name'] || c['CompanyName']}" }
      out << ('=' * 78)

      # Braces are required. Ruby 3 hands a brace-less trailing hash to the
      # method's keyword parameters, and get_all has one (`limit:`).
      tickets = api.get_all('/v1/tickets', { 'ClientIds' => ids.join(','),
                                             'SortBy' => 'updatedOn', 'SortOrder' => 'desc' })
      by_base = Hash.new(0)
      tickets.each { |t| by_base[api.base_status_id(nested(t, 'Status', 'Id'))] += 1 }

      out << "Tickets: #{tickets.size} total - " +
             by_base.sort_by { |k, _| k.to_i }
                    .map { |b, n| "#{Gorelo::BASE_NAMES[b] || (b.nil? ? 'UNKNOWN' : "base #{b}")} #{n}" }
                    .join(' · ')

      active = tickets.reject { |t| merged?(t) }.select do |t|
        base = api.base_status_id(nested(t, 'Status', 'Id'))
        base.nil? || Gorelo::ACTIVE_BASES.include?(base) || base == Gorelo::BASE_SOLVED
      end
      unless active.empty?
        out << ''
        out << "Outstanding tickets (#{active.size}, merged excluded, includes Billing and Standing):"
        active.sort_by { |t| -(days_since(t['UpdatedOn']) || 0) }.first(25).each do |t|
          out << "  #{pad(t['DisplayNumber'] || "G-#{t['Number']}", 9)}#{pad(nested(t, 'Status', 'Name'), 22)}" \
                 "#{age(t['UpdatedOn'])} idle  #{clip(t['Title'], 55)}"
        end
      end

      contacts = api.get_all('/v1/contacts', { 'ClientId' => ids.first.to_s })
      contacts = matched.drop(1).each_with_object(contacts) do |c, acc|
        acc.concat(api.get_all('/v1/contacts', { 'ClientId' => c['Id'].to_s }))
      end
      out << ''
      out << "Contacts (#{contacts.size}):"
      contacts.first(25).each do |c|
        name = [c['FirstName'], c['LastName']].compact.join(' ')
        name = c['Name'] if name.strip.empty?
        out << "  #{pad(name, 30)}#{c['Email'] || c['EmailAddress']}"
      end

      if args.fetch('include_devices', true)
        # Server-side since the 2026-08-21 release. The local select is kept as
        # a belt-and-braces filter: if a tenant has not had the update yet,
        # ClientIds is silently ignored and the full fleet comes back, which
        # would otherwise report every device in the organisation as this
        # client's.
        agents = api.get_all('/v1/assets/agents', { 'ClientIds' => ids.join(',') })
        want   = ids.map(&:to_s)
        mine   = agents.select do |a|
          [a['ClientId'], nested(a, 'Client', 'Id'), a['CompanyId'], a['OrganizationId']]
            .compact.map(&:to_s).any? { |v| want.include?(v) }
        end
        out << ''
        out << "Devices (#{mine.size} of #{agents.size} in the fleet):"
        mine.first(40).each do |a|
          name = a['Name'] || a['HostName'] || a['ComputerName'] || a['Id']
          os   = a['OperatingSystem'] || nested(a, 'Os', 'Name') || ''
          seen = a['LastSeenOn'] || a['LastCheckInOn'] || a['UpdatedOn']
          out << "  #{pad(name, 26)}#{pad(os, 34)}last seen #{age(seen)} ago"
        end
      end

      out.join("\n")
    end
  end

  # ---- 5. get contact -----------------------------------------------------

  def get_contact(server, api)
    server.tool(
      name:  'gorelo_get_contact',
      title: 'Find a Gorelo contact',
      description: 'Search contacts by name or email across all clients. The contacts endpoint ' \
                   'filters on ClientId (singular) only, so an unfiltered search pages the whole ' \
                   'list once and filters locally - which is still far fewer requests than one ' \
                   'call per client.',
      input_schema: {
        type: 'object',
        properties: {
          term:   { type: 'string', description: 'Name or email fragment.' },
          client: { type: 'string', description: 'Optionally narrow to one client first.' },
          limit:  { type: 'integer', description: 'Default 25.' }
        },
        required: ['term'],
        additionalProperties: false
      }
    ) do |args|
      limit  = (args['limit'] || 25).to_i.clamp(1, 200)
      needle = args['term'].to_s.downcase

      rows =
        if args['client'].to_s.strip.empty?
          api.get_all('/v1/contacts')
        else
          api.resolve_clients(args['client']).flat_map do |c|
            api.get_all('/v1/contacts', { 'ClientId' => c['Id'].to_s })
          end
        end

      hits = rows.select do |c|
        [c['FirstName'], c['LastName'], c['Name'], c['Email'], c['EmailAddress'], c['Phone'],
         c['MobilePhone']].compact.join(' ').downcase.include?(needle)
      end

      next "No contact matches #{args['term'].inspect} across #{rows.size} contacts." if hits.empty?

      out = ["#{hits.size} of #{rows.size} contacts match #{args['term'].inspect}:", '']
      hits.first(limit).each do |c|
        name = [c['FirstName'], c['LastName']].compact.join(' ')
        name = c['Name'].to_s if name.strip.empty?
        out << "#{pad(name, 26)}#{pad(c['Email'] || c['EmailAddress'], 34)}" \
               "#{pad(c['Phone'] || c['MobilePhone'], 16)}#{api.client_name(c['ClientId'])}"
      end
      out << "#{hits.size - limit} more not shown." if hits.size > limit
      out.join("\n")
    end
  end

  # ---- 6. list assets -----------------------------------------------------

  def list_assets(server, api)
    server.tool(
      name:  'gorelo_list_assets',
      title: 'List Gorelo managed devices',
      description: 'Managed agents/devices. Narrow by client, by any text on the record, or to ' \
                   'devices not seen for N days - the fastest way to find agents still billing ' \
                   'for a client who left. Shows the Description and warranty/term end date ' \
                   'under each row, which is where reportable notes have to live because Gorelo ' \
                   'does not expose asset TAGS through the API at all.',
      input_schema: {
        type: 'object',
        properties: {
          client:        { type: 'string', description: 'Client name fragment or id.' },
          search:        { type: 'string', description: 'Matched against every field on the asset, including Description - so notes written there (e.g. a rental ContractEnd date) are searchable.' },
          stale_days:    { type: 'integer', description: 'Only devices not seen for at least this many days.' },
          limit:         { type: 'integer', description: 'Default 50.' }
        },
        additionalProperties: false
      }
    ) do |args|
      limit = (args['limit'] || 50).to_i.clamp(1, 500)

      # The 2026-08-21 release added ClientIds filtering to /v1/assets/agents.
      # Before it, this paged the entire fleet - 626 devices on a real tenant -
      # to show four. Verified applied, not ignored: the response FilterHash
      # differs from the unfiltered one and TotalCount drops accordingly.
      query = {}
      scope = nil
      if args['client'] && !args['client'].to_s.empty?
        matched = api.resolve_clients(args['client'])
        next "No client matches #{args['client'].inspect}." if matched.empty?

        query['ClientIds'] = matched.map { |c| c['Id'] }.join(',')
        scope = matched.map { |c| c['Name'] }.first(3).join(' + ')
      end

      agents = api.get_all('/v1/assets/agents', query)
      rows   = agents

      if args['search'] && !args['search'].to_s.empty?
        needle = args['search'].to_s.downcase
        rows = rows.select { |a| a.values.map(&:to_s).join(' ').downcase.include?(needle) }
      end

      seen_of = lambda { |a| a['LastSeenOn'] || a['LastCheckInOn'] || a['UpdatedOn'] }

      if args['stale_days']
        n = args['stale_days'].to_i
        rows = rows.select { |a| (days_since(seen_of.call(a)) || 9_999) >= n }
      end

      rows = rows.sort_by { |a| -(days_since(seen_of.call(a)) || 9_999) }

      header = "#{rows.size} of #{agents.size} devices match"
      header += " (client=#{scope})" if scope
      out = ["#{header}.", '']
      out << "#{pad('Device', 26)}#{pad('Client', 26)}#{pad('OS', 28)}last seen"
      out << ('-' * 92)
      rows.first(limit).each do |a|
        cid = a['ClientId'] || nested(a, 'Client', 'Id') || a['CompanyId']
        out << "#{pad(a['Name'] || a['HostName'] || a['ComputerName'] || a['Id'], 26)}" \
               "#{pad(api.client_name(cid) || cid, 26)}" \
               "#{pad(a['OsName'] || a['OperatingSystem'] || nested(a, 'Os', 'Name'), 28)}" \
               "#{age(seen_of.call(a))} ago"

        # Description and the warranty dates are the only writable fields the
        # asset API exposes. Gorelo's asset TAGS are not in the API at all, so
        # anything that has to be reportable - a rental contract end date, for
        # instance - has to live in one of these.
        #
        # The 2026-08-21 release split WarrantyExpiryDate into WarrantyStartDate
        # and WarrantyEndDate. The old name is still read, so this works against
        # a tenant on either version. Worth noting how this one failed: the
        # renamed field simply vanished from the output with no error at all,
        # which for a field carrying rental contract end dates is the quiet kind
        # of wrong.
        notes = []
        notes << a['Description'].to_s.strip unless a['Description'].to_s.strip.empty?
        warranty_end = a['WarrantyEndDate'] || a['WarrantyExpiryDate']
        notes << "warranty/term ends #{warranty_end}" if warranty_end
        out << "#{' ' * 4}\u21B3 #{clip(notes.join(' · '), 100)}" unless notes.empty?
      end
      out << "#{rows.size - limit} more not shown." if rows.size > limit
      out.join("\n")
    end
  end


  # ---- 7. billing review --------------------------------------------------

  # Only possible since the 2026-08-21 release, which put a time and billing
  # breakdown on GET /v1/tickets/{id}. Before it, "does this ticket have hours
  # on it?" could not be answered outside Gorelo's UI, so a Billing queue was
  # an undifferentiated pile.
  #
  # The split this produces is the point. A ticket with billable hours needs
  # an invoice. A ticket with NO hours is almost always a recurring charge that
  # was never set up - a different job, for a different person, that loses its
  # monthly value every month rather than once. From outside the ticket the two
  # look identical.
  def billing_review(server, api)
    server.tool(
      name:  'gorelo_billing_review',
      title: 'Review the Billing queue with recorded time',
      description: <<~TEXT,
        Every ticket in a given status, with its recorded hours, split into what can be
        invoiced and what cannot. Sorted longest-waiting first.

        Splits the queue three ways:
          - BILLABLE HOURS - ready to invoice now
          - TIME BUT NONE BILLABLE - in the queue for some other reason
          - NO TIME RECORDED - almost always a recurring charge never set up

        COST: one request per ticket, because the time breakdown only exists on the
        get-by-id endpoint and not on list rows. The reply states how many it made.
      TEXT
      input_schema: {
        type: 'object',
        properties: {
          status:   { type: 'string', description: 'Status NAME to review, matched as a fragment. Default "Billing". Use "solved" to sweep the whole solved base.' },
          assignee: { type: 'string', description: 'Gorelo user id, email, name fragment, or "me". Default "anyone".' },
          min_days: { type: 'integer', description: 'Only tickets in that status for at least this many days. Default 0.' },
          limit:    { type: 'integer', description: 'Max tickets to inspect. Default 25 - and each one costs a request.' }
        },
        additionalProperties: false
      }
    ) do |args|
      wanted   = (args['status'] || 'Billing').to_s.downcase
      limit    = (args['limit'] || 25).to_i.clamp(1, 100)
      min_days = (args['min_days'] || 0).to_i

      ids = if wanted == 'solved'
              api.statuses.values.select { |st| st['BaseStatusId'] == Gorelo::BASE_SOLVED }
            else
              api.statuses.values.select { |st| st['Name'].to_s.downcase.include?(wanted) }
            end
      if ids.empty?
        next "No Gorelo status matches #{args['status'].inspect}. Statuses: " \
             "#{api.statuses.values.map { |st| st['Name'] }.join(', ')}"
      end

      query = { 'StatusIds' => ids.map { |st| st['Id'] }.join(',') }
      assignee = args['assignee'] || 'anyone'
      unless assignee.to_s.downcase == 'anyone'
        query['LeadAssigneeIds'] = api.resolve_user_id(assignee).to_s
      end

      rows = api.get_all('/v1/tickets', query)
               .reject { |t| merged?(t) }
               .select { |t| (days_since(t['StatusUpdatedOn']) || 0) >= min_days }
               .sort_by { |t| -(days_since(t['StatusUpdatedOn']) || 0) }

      if rows.empty?
        next "No tickets in #{ids.map { |st| st['Name'] }.join('/')}" \
             "#{min_days.positive? ? " for #{min_days}+ days" : ''}."
      end

      inspected = rows.first(limit)
      calls     = 0
      billable  = []
      unbillable = []
      untimed   = []

      inspected.each do |t|
        detail = begin
          calls += 1
          api.get("/v1/tickets/#{t['Id']}")['Data']
        rescue Gorelo::Error
          nil
        end
        full = detail.is_a?(Hash) ? t.merge(detail) : t
        time = full['Time'] || {}
        b    = nested(time, 'Breakdown', 'Billable', 'AdjustedHours').to_f
        act  = time['ActualHours'].to_f

        if b.positive?      then billable << [full, act, b]
        elsif act.positive? then unbillable << [full, act, b]
        else                     untimed << [full, act, b]
        end
      end

      line = lambda do |full, act, b|
        num    = full['DisplayNumber'] || "G-#{full['Number']}"
        client = api.client_name(full['ClientId']) || (full['ClientId'] ? "client #{full['ClientId']}" : '⚠ NO CLIENT')
        days   = days_since(full['StatusUpdatedOn'])
        row    = "#{pad(num, 10)}#{pad(client, 30)}#{format('%5dd', days || 0)}  " \
                 "#{format('%5.2fh rec / %5.2fh billable', act, b)}  #{clip(full['Title'], 44)}"
        extra  = []
        if (r = status_reason(full)) then extra << r end
        if (pr = full['Products']) && pr['Count'].to_i.positive?
          extra << "#{pr['Count']} product line(s), #{format('%.2f', pr['TotalAmount'].to_f)}"
        end
        extra.empty? ? row : "#{row}\n#{' ' * 12}\u21B3 #{clip(extra.join(' · '), 96)}"
      end

      out = ["#{rows.size} ticket(s) in #{ids.map { |st| st['Name'] }.join('/')}" \
             "#{min_days.positive? ? " for #{min_days}+ days" : ''}. " \
             "Inspected #{inspected.size} (#{calls} extra request(s) for the time breakdown)."]
      out << ''

      total_billable = billable.sum { |(_, _, b)| b }
      out << "READY TO INVOICE - #{billable.size} ticket(s), #{format('%.2f', total_billable)}h billable"
      out << ('-' * 118)
      billable.each { |a| out << line.call(*a) }
      out << '  (none)' if billable.empty?

      out << ''
      out << "TIME RECORDED BUT NONE BILLABLE - #{unbillable.size} ticket(s)"
      out << 'These are in the queue for some other reason - a recurring charge, or an invoice'
      out << 'raised in another system. Worth re-filing so the queue means one thing.'
      out << ('-' * 118)
      unbillable.each { |a| out << line.call(*a) }
      out << '  (none)' if unbillable.empty?

      out << ''
      out << "NO TIME RECORDED - #{untimed.size} ticket(s)"
      out << 'Almost always a recurring charge that was never set up. These lose their monthly'
      out << 'value every month, not once, so they usually outrank the invoicing above.'
      out << ('-' * 118)
      untimed.each { |a| out << line.call(*a) }
      out << '  (none)' if untimed.empty?

      if rows.size > inspected.size
        out << ''
        out << "#{rows.size - inspected.size} more not inspected - raise limit to include them."
      end
      out.join("\n")
    end
  end


  # ---- 8. time report -----------------------------------------------------

  # WHAT THIS CANNOT DO, stated up front because it shapes everything below:
  # Gorelo's API has NO time-entry endpoint. The whole public surface is
  # fourteen paths and none of them expose a timesheet, a work entry, or hours
  # by user. Confirmed against the OpenAPI spec, not inferred from a 404.
  #
  # The only time data that exists is a per-TICKET total on
  # GET /v1/tickets/{id}, added 2026-08-21. So "technician time" here means
  # ticket hours attributed to each ticket's LEAD ASSIGNEE - which counts an
  # assisting technician's hours against the lead. That is a real limitation,
  # not a rounding error, and the report says so every time rather than
  # presenting an approximation as a measurement.
  #
  # What it IS good for: realisation - what fraction of recorded hours are
  # billable - which is a ratio, and survives the attribution problem far
  # better than a per-person total does.
  def time_report(server, api)
    server.tool(
      name:  'gorelo_time_report',
      title: 'Report recorded time and realisation',
      description: <<~TEXT,
        Recorded hours, invoiceable hours and the billable share, over a window, grouped by
        technician or client.

        ⚠ Gorelo has NO per-user time API - the entire spec is 14 paths and none expose
        timesheets. Hours are per TICKET and are attributed here to the ticket's LEAD
        assignee, so an assisting technician's time counts against the lead. The reply
        states how many tickets that affects. Treat per-person totals as indicative and
        the REALISATION percentage as the reliable number.

        COST AND TIME: one request per ticket, because the breakdown exists only on the
        get-by-id endpoint. 500+ tickets are updated org-wide in a typical month, so scope
        it - by assignee, by client, or with a short window - and expect roughly a second
        per ticket. The reply states the request count.
      TEXT
      input_schema: {
        type: 'object',
        properties: {
          days:     { type: 'integer', description: 'Window in days, matched on the ticket UpdatedOn date. Default 30.' },
          assignee: { type: 'string', description: 'Gorelo user id, email, name fragment, or "me". Use "anyone" to cover the organisation. Default "me".' },
          client:   { type: 'string', description: 'Restrict to one or more clients (name fragment, comma-separated).' },
          group_by: { type: 'string', enum: %w[technician client], description: 'Default "client" for one technician, "technician" for "anyone".' },
          limit:    { type: 'integer', description: 'Max tickets to inspect - each costs a request. Default 150.' }
        },
        additionalProperties: false
      }
    ) do |args|
      days  = (args['days'] || 30).to_i.clamp(1, 400)
      limit = (args['limit'] || 150).to_i.clamp(1, 400)
      since = (Time.now.utc - (days * 86_400)).strftime('%Y-%m-%d')

      query    = { 'UpdatedSince' => since }
      scope    = ["last #{days}d"]
      assignee = args['assignee'] || 'me'
      org_wide = assignee.to_s.downcase == 'anyone'

      unless org_wide
        query['LeadAssigneeIds'] = api.resolve_user_id(assignee).to_s
        scope << "assignee=#{assignee}"
      end

      if args['client'] && !args['client'].to_s.empty?
        matched = api.resolve_clients(args['client'])
        next "No client matches #{args['client'].inspect}." if matched.empty?

        query['ClientIds'] = matched.map { |c| c['Id'] }.join(',')
        scope << "client=#{matched.map { |c| c['Name'] }.first(3).join(' + ')}"
      end

      rows = api.get_all('/v1/tickets', query).reject { |t| merged?(t) }
      if rows.empty?
        next "No tickets #{scope.join(', ')}."
      end

      inspected  = rows.first(limit)
      with_assist = inspected.count { |t| Array(t['AssistingAssigneeIds']).any? }
      calls = 0
      buckets = Hash.new { |h, k| h[k] = { actual: 0.0, adjusted: 0.0, billable: 0.0, tickets: 0 } }
      totals  = { actual: 0.0, adjusted: 0.0, billable: 0.0 }
      biggest = []

      group_by = args['group_by'] || (org_wide ? 'technician' : 'client')

      inspected.each_with_index do |t, i|
        server.log("time report: #{i + 1}/#{inspected.size} tickets inspected") if ((i + 1) % 25).zero?
        detail = begin
          calls += 1
          api.get("/v1/tickets/#{t['Id']}")['Data']
        rescue Gorelo::Error
          nil
        end
        next unless detail.is_a?(Hash)

        time = detail['Time'] || {}
        act  = time['ActualHours'].to_f
        adj  = time['AdjustedHours'].to_f
        bil  = nested(time, 'Breakdown', 'Billable', 'AdjustedHours').to_f
        next if act.zero? && adj.zero?

        key = if group_by == 'technician'
                api.user_name(t['LeadAssigneeId']) || "user #{t['LeadAssigneeId']}"
              else
                api.client_name(t['ClientId']) || (t['ClientId'] ? "client #{t['ClientId']}" : '⚠ NO CLIENT')
              end
        b = buckets[key]
        b[:actual] += act
        b[:adjusted] += adj
        b[:billable] += bil
        b[:tickets] += 1
        totals[:actual] += act
        totals[:adjusted] += adj
        totals[:billable] += bil
        biggest << [t, act, adj, bil]
      end

      pct = lambda do |part, whole|
        whole.zero? ? '   -' : format('%3d%%', ((part / whole) * 100).round)
      end

      out = ["Recorded time - #{scope.join(', ')}."]
      out << "#{rows.size} ticket(s) in scope, #{inspected.size} inspected " \
             "(#{calls} extra request(s) for the time breakdown); " \
             "#{buckets.values.sum { |b| b[:tickets] }} of them carry time."
      out << ''
      out << '⚠ Gorelo has no per-user time API. Hours are attributed to each ticket\'s LEAD'
      out << "  assignee. #{with_assist} of the inspected tickets also have assisting assignees, so"
      out << '  those hours are counted against the lead. Per-person totals are indicative;'
      out << '  the realisation percentage is the number to trust.'
      out << ''
      out << format('TOTAL   %7.2fh recorded   %7.2fh to invoice   %7.2fh billable   ' \
                    'realisation %s',
                    totals[:actual], totals[:adjusted], totals[:billable],
                    pct.call(totals[:billable], totals[:adjusted]))
      if totals[:adjusted] > totals[:actual]
        out << format('        adjusted UP by %.2fh across the window', totals[:adjusted] - totals[:actual])
      elsif totals[:actual] > totals[:adjusted]
        out << format('        written DOWN by %.2fh across the window', totals[:actual] - totals[:adjusted])
      end

      out << ''
      out << "By #{group_by}"
      out << "#{'Tkts'.rjust(5)}#{'Recorded'.rjust(11)}#{'Invoice'.rjust(11)}" \
             "#{'Billable'.rjust(11)}#{'Real.'.rjust(7)}  #{group_by.capitalize}"
      out << ('-' * 96)
      buckets.sort_by { |_, b| -b[:adjusted] }.each do |name, b|
        out << "#{b[:tickets].to_s.rjust(5)}#{format('%10.2fh', b[:actual])}" \
               "#{format('%10.2fh', b[:adjusted])}#{format('%10.2fh', b[:billable])}" \
               "#{pct.call(b[:billable], b[:adjusted]).rjust(7)}  #{clip(name, 44)}"
      end

      # Non-billable hours are where the margin actually goes, so name the
      # worst offenders rather than leaving them inside a percentage.
      leak = biggest.select { |(_, _, adj, bil)| adj - bil > 0.25 }
                    .sort_by { |(_, _, adj, bil)| -(adj - bil) }
      if leak.any?
        lost = leak.sum { |(_, _, adj, bil)| adj - bil }
        out << ''
        out << format('NON-BILLABLE - %.2fh across %d ticket(s), largest first', lost, leak.size)
        out << ('-' * 96)
        leak.first(12).each do |(t, _act, adj, bil)|
          out << "#{pad(t['DisplayNumber'] || "G-#{t['Number']}", 10)}" \
                 "#{pad(api.client_name(t['ClientId']) || '?', 28)}" \
                 "#{format('%6.2fh', adj - bil)}  #{clip(t['Title'], 48)}"
        end
        out << "  … #{leak.size - 12} more" if leak.size > 12
      end

      if rows.size > inspected.size
        out << ''
        out << "⚠ #{rows.size - inspected.size} ticket(s) in scope were NOT inspected (limit " \
               "#{limit}). Every figure above covers only the #{inspected.size} that were."
      end
      out.join("\n")
    end
  end


  # ---- 9. first-response report -------------------------------------------

  # Sla.FirstResponse.ElapsedBusinessMinutes is on every LIST row, so unlike
  # the time report this costs no extra requests at all - hundreds of tickets
  # in one or two calls. The field was renamed on 2026-08-21 (it was a flat
  # "SLA Minutes"), which is why nothing used it before.
  #
  # BUSINESS minutes, not wall clock: the figure already excludes nights and
  # weekends. A ticket raised at 4:55pm and answered at 9:05am is a few
  # minutes here, not seventeen hours, and reporting it as elapsed time would
  # make the team look far worse than it is.
  def response_report(server, api)
    server.tool(
      name:  'gorelo_response_report',
      title: 'First-response times',
      description: <<~TEXT,
        How long tickets wait for their first response, grouped by technician, client or
        group/brand. Median, 90th percentile and worst, plus the share answered within
        target.

        Costs NO extra requests - the SLA figure rides on the ticket list - so this runs
        over hundreds of tickets in seconds, unlike gorelo_time_report.

        The figures are BUSINESS minutes: nights and weekends are already excluded, so a
        ticket raised at 4:55pm and answered at 9:05am counts as a few minutes, not
        seventeen hours.

        Tickets with NO first-response record are counted and reported separately rather
        than dropped - they are usually tickets a technician raised themselves, and
        silently excluding them flatters every other number.
      TEXT
      input_schema: {
        type: 'object',
        properties: {
          days:           { type: 'integer', description: 'Window in days, on ticket creation date. Default 30.' },
          assignee:       { type: 'string', description: 'Gorelo user id, email, name fragment, or "me". Use "anyone" for the organisation. Default "anyone".' },
          client:         { type: 'string', description: 'Restrict to one or more clients (name fragment, comma-separated).' },
          group_by:       { type: 'string', enum: %w[technician client group], description: 'Default "technician". "group" splits by Gorelo group, which is how separate desks or brands are modelled.' },
          target_minutes: { type: 'integer', description: 'First-response target in BUSINESS minutes. Default 60.' },
          limit:          { type: 'integer', description: 'Max groups shown. Default 20.' }
        },
        additionalProperties: false
      }
    ) do |args|
      days    = (args['days'] || 30).to_i.clamp(1, 400)
      target  = (args['target_minutes'] || 60).to_i.clamp(1, 10_000)
      limit   = (args['limit'] || 20).to_i.clamp(1, 100)
      since   = (Time.now.utc - (days * 86_400)).strftime('%Y-%m-%d')
      query   = { 'CreatedSince' => since }
      scope   = ["last #{days}d"]

      assignee = args['assignee'] || 'anyone'
      unless assignee.to_s.downcase == 'anyone'
        query['LeadAssigneeIds'] = api.resolve_user_id(assignee).to_s
        scope << "assignee=#{assignee}"
      end

      if args['client'] && !args['client'].to_s.empty?
        matched = api.resolve_clients(args['client'])
        next "No client matches #{args['client'].inspect}." if matched.empty?

        query['ClientIds'] = matched.map { |c| c['Id'] }.join(',')
        scope << "client=#{matched.map { |c| c['Name'] }.first(3).join(' + ')}"
      end

      rows = api.get_all('/v1/tickets', query).reject { |t| merged?(t) }
      next "No tickets created in the #{scope.join(', ')}." if rows.empty?

      group_by = args['group_by'] || 'technician'
      key_of = lambda do |t|
        case group_by
        when 'client' then api.client_name(t['ClientId']) || (t['ClientId'] ? "client #{t['ClientId']}" : '⚠ NO CLIENT')
        when 'group'  then api.group_name(t['PrimaryGroupId']) || "group #{t['PrimaryGroupId']}"
        else               api.user_name(t['LeadAssigneeId']) || "user #{t['LeadAssigneeId']}"
        end
      end

      answered = []
      missing  = []
      rows.each do |t|
        mins = nested(t, 'Sla', 'FirstResponse', 'ElapsedBusinessMinutes')
        if mins.nil?
          missing << t
        else
          answered << [t, mins.to_f]
        end
      end

      if answered.empty?
        next "#{rows.size} ticket(s) in scope, but none carries a first-response time. " \
             'Gorelo records one only when a reply follows the ticket being raised.'
      end

      pctile = lambda do |sorted, p|
        return 0.0 if sorted.empty?

        sorted[[((sorted.size - 1) * p).round, sorted.size - 1].min]
      end

      hm = lambda do |mins|
        m = mins.round
        m < 60 ? "#{m}m" : "#{m / 60}h #{(m % 60).to_s.rjust(2, '0')}m"
      end

      all_mins = answered.map { |(_, m)| m }.sort
      within   = answered.count { |(_, m)| m <= target }

      out = ["First response - #{scope.join(', ')}. BUSINESS minutes, nights and weekends excluded."]
      out << "#{rows.size} ticket(s) created; #{answered.size} have a first-response time."
      out << ''
      out << "OVERALL   median #{hm.call(pctile.call(all_mins, 0.5))}   " \
             "90th pct #{hm.call(pctile.call(all_mins, 0.9))}   " \
             "worst #{hm.call(all_mins.last)}   " \
             "within #{target}m: #{((within.to_f / answered.size) * 100).round}% " \
             "(#{within}/#{answered.size})"

      buckets = Hash.new { |h, k| h[k] = [] }
      answered.each { |(t, m)| buckets[key_of.call(t)] << m }

      out << ''
      out << "By #{group_by}"
      out << "#{'Tkts'.rjust(5)}#{'Median'.rjust(10)}#{'90th'.rjust(10)}#{'Worst'.rjust(10)}" \
             "#{'In target'.rjust(11)}  #{group_by.capitalize}"
      out << ('-' * 100)
      buckets.sort_by { |_, v| -pctile.call(v.sort, 0.5) }.first(limit).each do |name, v|
        sorted = v.sort
        ok     = v.count { |m| m <= target }
        out << "#{v.size.to_s.rjust(5)}#{hm.call(pctile.call(sorted, 0.5)).rjust(10)}" \
               "#{hm.call(pctile.call(sorted, 0.9)).rjust(10)}#{hm.call(sorted.last).rjust(10)}" \
               "#{"#{((ok.to_f / v.size) * 100).round}%".rjust(11)}  #{clip(name, 40)}"
      end
      out << "  … #{buckets.size - limit} more" if buckets.size > limit

      worst = answered.select { |(_, m)| m > target }.sort_by { |(_, m)| -m }
      if worst.any?
        out << ''
        out << "OVER TARGET - #{worst.size} ticket(s) past #{target} business minutes, worst first"
        out << ('-' * 100)
        worst.first(10).each do |(t, m)|
          out << "#{pad(t['DisplayNumber'] || "G-#{t['Number']}", 10)}" \
                 "#{pad(api.client_name(t['ClientId']) || '?', 26)}#{hm.call(m).rjust(9)}  " \
                 "#{clip(t['Title'], 46)}"
        end
        out << "  … #{worst.size - 10} more" if worst.size > 10
      end

      if missing.any?
        out << ''
        out << "NO FIRST-RESPONSE RECORD - #{missing.size} ticket(s), excluded from every figure"
        out << 'above. Usually tickets a technician raised themselves, so there was no client'
        out << 'waiting - but worth a look if the count is high.'
      end
      out.join("\n")
    end
  end

  # ---- 10. add ticket comment (the first of two writes) -------------------

  # Confirmed from the OpenAPI spec (CreatePublicCommentCommand):
  #   ConversationTypeId  1 Public, 2 Private, 3 Side Conversation, 4 Approval
  #   Body                HTML
  #   CreatedByName       display name for the author
  #   ConversationId      REJECTED for Public and Private - never send it
  #
  # ConversationTypeId is OPTIONAL, which means omitting it lets the server
  # choose. It is always sent explicitly here: a private note that silently
  # posts as public is the worst thing this tool could do.
  CONVERSATION_PUBLIC  = 1
  CONVERSATION_PRIVATE = 2

  # Body is HTML. Plain text with newlines would render as one run-on blob,
  # and any < or & in it would be swallowed or corrupt the markup.
  def to_html(text)
    escaped = text.to_s
                  .gsub('&', '&amp;')
                  .gsub('<', '&lt;')
                  .gsub('>', '&gt;')
    escaped.split(/\n{2,}/)
           .map { |para| "<p>#{para.strip.gsub(/\n/, '<br />')}</p>" }
           .join
  end

  def add_ticket_comment(server, api)
    server.tool(
      name:  'gorelo_add_ticket_comment',
      title: 'Add a comment to a Gorelo ticket',
      description: <<~TEXT,
        Post a comment on a ticket. This is the ONLY tool that writes anything.

        Safety:
          - disabled unless GORELO_ALLOW_WRITES=true
          - `confirm: true` is required on every call
          - ConversationTypeId is ALWAYS sent explicitly: 2 (Private) unless visibility
            is set to "client", which sends 1 (Public) and may email the client
          - identical comments on the same ticket within 24 hours are refused, so a
            retried call cannot post twice
      TEXT
      read_only: false,
      input_schema: {
        type: 'object',
        properties: {
          ticket:     { type: 'string', description: 'Ticket number such as G-13933, or a ticket id.' },
          body:       { type: 'string', description: 'The comment text. Sent as HTML; plain text is converted.' },
          visibility: { type: 'string', enum: %w[internal client], description: 'Default "internal" (ConversationTypeId 2). "client" posts publicly (1).' },
          author:     { type: 'string', description: 'Optional display name for the comment author.' },
          confirm:    { type: 'boolean', description: 'Must be true. A deliberate speed bump on the only write path.' }
        },
        required: %w[ticket body confirm],
        additionalProperties: false
      }
    ) do |args|
      next 'Writes are disabled. Set GORELO_ALLOW_WRITES=true in .env and restart.' unless api.writes_allowed?
      next 'Refused: `confirm` must be true.' unless args['confirm'] == true
      next 'Refused: empty comment body.' if args['body'].to_s.strip.empty?

      visibility = (args['visibility'] || 'internal').downcase
      internal   = visibility != 'client'
      type_id    = internal ? CONVERSATION_PRIVATE : CONVERSATION_PUBLIC

      t = find_ticket(api, args['ticket'])
      next "Could not find ticket #{args['ticket']} - nothing was posted." unless t

      key = api.fingerprint(t['Id'], args['body'].strip, type_id)
      if api.write_fingerprint_seen?(key)
        next "Refused: an identical comment was already posted to #{t['DisplayNumber']} in the " \
             'last 24 hours. Nothing was sent.'
      end

      payload = { 'ConversationTypeId' => type_id, 'Body' => to_html(args['body']) }
      payload['CreatedByName'] = args['author'] if args['author']
      # ConversationId is rejected for Public and Private - deliberately absent.

      begin
        api.post("/v1/tickets/#{t['Id']}/comments", payload)
      rescue Gorelo::Error => e
        next "Nothing was posted. #{e.message}"
      end

      api.record_write(key, "#{t['DisplayNumber']} ConversationTypeId=#{type_id}")
      "Posted #{internal ? 'a PRIVATE (internal) note' : 'a PUBLIC, client-visible comment'} " \
        "to #{t['DisplayNumber']} - #{t['Title']}."
    end
  end

  # ---- 8. api probe -------------------------------------------------------

  def api_probe(server, api)
    server.tool(
      name:  'gorelo_api_probe',
      title: 'Probe a Gorelo API path (read-only)',
      description: 'Issue a raw GET against any Gorelo path and return the truncated JSON. ' \
                   'Read-only, and the way to discover an endpoint shape before a tool is ' \
                   'written for it. Exploring the API this way is what revealed that Gorelo ' \
                   'uses cursor pagination and PascalCase in the first place.',
      input_schema: {
        type: 'object',
        properties: {
          path:  { type: 'string', description: 'e.g. /v1/tickets/statuses' },
          query: { type: 'object', description: 'Query parameters, e.g. {"PageSize": 1}', additionalProperties: true },
          chars: { type: 'integer', description: 'Max characters of JSON to return. Default 4000.' }
        },
        required: ['path'],
        additionalProperties: false
      }
    ) do |args|
      path = args['path'].to_s
      next 'Refused: path must start with /v1/' unless path.start_with?('/v1/')

      query = (args['query'] || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s }
      query['PageSize'] ||= '3'

      body  = api.get(path, query)
      chars = (args['chars'] || 4000).to_i.clamp(200, 40_000)
      json  = JSON.pretty_generate(body)

      pagination = body.dig('DataContext', 'Pagination')
      header = "GET #{path}?#{URI.encode_www_form(query)}\n"
      header += "Pagination: #{pagination.inspect}\n" if pagination
      header += "Data is #{body['Data'].is_a?(Array) ? "an array of #{body['Data'].size}" : body['Data'].class}\n\n"

      header + (json.length > chars ? "#{json[0, chars]}\n… truncated (#{json.length} chars total)" : json)
    end
  end

  # ---- 11. update ticket (the second and last write) ----------------------
  #
  # Scoped to TWO fields: client and status. Not the title, not the assignee,
  # not the priority, and never a deletion.
  #
  # THE PROBLEM THIS TOOL IS BUILT AROUND: the exact PATCH payload schema is
  # not knowable from here - the published swagger.json is too large to read
  # through a summarising fetch without silent truncation. And this API IGNORES
  # fields it does not recognise rather than rejecting them, which is the same
  # trap as the query parameters: a wrong field name returns 200 and changes
  # nothing, which reads exactly like success.
  #
  # So this tool does not trust the write. It reads the ticket, writes, reads it
  # back, and CONFIRMS the value actually changed. If it did not, it says so
  # loudly and names the likely cause instead of reporting a write that never
  # happened. That turns an unknown schema from a silent failure into a
  # detected one.
  def update_ticket(server, api)
    server.tool(
      name:  'gorelo_update_ticket',
      title: 'Set a ticket\'s client or status',
      description: <<~TEXT,
        Change the CLIENT or the STATUS on one ticket. Nothing else is writable through this
        tool - not the title, not the assignee, not the priority - and there is no delete
        path anywhere in this server.

        Built for two specific recurring problems: a ticket with NO client attached never
        appears in any client-scoped review, and a ticket parked in the wrong status sits
        in a queue that then means two different things.

        Every change is VERIFIED: the ticket is read, written, and read back, and the reply
        states the before and after values. Gorelo ignores unrecognised fields rather than
        rejecting them, so a write that silently did nothing would otherwise look identical
        to one that worked.

        Requires GORELO_ALLOW_WRITES=true and confirm: true.
      TEXT
      input_schema: {
        type: 'object',
        properties: {
          ticket:  { type: 'string', description: 'Ticket number such as G-13529, or a ticket id.' },
          client:  { type: 'string', description: 'Client name fragment or id to attach. Must match exactly one client.' },
          status:  { type: 'string', description: 'Status name to move the ticket to, e.g. "Closed", "Billing". Matched against the live status list.' },
          author:  { type: 'string', description: 'Display name recorded against the change (UpdatedByName). Defaults to "Gorelo MCP" so an automated edit is never attributed to a person.' },
          confirm: { type: 'boolean', description: 'Must be true. Nothing is written without it.' }
        },
        required: %w[ticket confirm],
        additionalProperties: false
      },
      read_only: false
    ) do |args|
      unless api.writes_allowed?
        next 'Writes are disabled. Set GORELO_ALLOW_WRITES=true in .env and restart to enable ' \
             'the two write tools.'
      end
      next 'Refused: confirm must be true. Nothing was written.' unless args['confirm'] == true

      if args['client'].to_s.strip.empty? && args['status'].to_s.strip.empty?
        next 'Nothing to do: give a client, a status, or both.'
      end

      t = find_ticket(api, args['ticket'])
      next "No ticket #{args['ticket']} found. Check the number." unless t

      # PATCH /v1/tickets/{ticketId} accepts far more than this: Title,
      # LeadAssigneeId, AssistingAssigneeIds, WatcherIds, PriorityId, TypeId,
      # TagIds, GroupIds, ContactId, CcContactIds, AgentAssetIds,
      # CustomAssetIds, UptimeIds and BillingOverride. Sending only ClientId and
      # StatusId is a deliberate restriction, not a limit of the endpoint -
      # reassigning a ticket or rewriting its title from here would change
      # someone else's queue without them seeing it happen.

      # UpdatedByName is the counterpart to CreatedByName on comments. Unlike a
      # comment, a status or client change leaves NO visible content in the
      # ticket - only a history line - so an unattributed one is indistinguishable
      # from a human doing it by hand. It is defaulted rather than optional for
      # that reason: automated edits should always look automated.
      payload = { 'UpdatedByName' => (args['author'].to_s.strip.empty? ? 'Gorelo MCP' : args['author']) }
      intent  = []

      unless args['client'].to_s.strip.empty?
        matched = api.resolve_clients(args['client'])
        next "No client matches #{args['client'].inspect}." if matched.empty?
        if matched.size > 1
          next "#{matched.size} clients match #{args['client'].inspect}: " \
               "#{matched.first(8).map { |c| "#{c['Id']} #{c['Name']}" }.join(', ')}. Narrow it."
        end

        payload['ClientId'] = matched.first['Id']
        intent << "client #{api.client_name(t['ClientId']) || '(none)'} → #{matched.first['Name']}"
      end

      unless args['status'].to_s.strip.empty?
        needle = args['status'].to_s.strip.downcase
        st = api.statuses.values.find { |x| x['Name'].to_s.downcase == needle } ||
             api.statuses.values.find { |x| x['Name'].to_s.downcase.include?(needle) }
        unless st
          next "No status matches #{args['status'].inspect}. Available: " \
               "#{api.statuses.values.map { |x| x['Name'] }.join(', ')}"
        end

        payload['StatusId'] = st['Id']
        intent << "status #{nested(t, 'Status', 'Name')} → #{st['Name']}"
      end

      before = { client: t['ClientId'], status: nested(t, 'Status', 'Id') }

      begin
        api.patch("/v1/tickets/#{t['Id']}", payload)
      rescue Gorelo::WritesDisabled => e
        next e.message
      rescue Gorelo::Error => e
        next "Gorelo refused the update: #{e.message}"
      end

      after_row = begin
        api.get("/v1/tickets/#{t['Id']}")['Data']
      rescue Gorelo::Error
        nil
      end
      unless after_row.is_a?(Hash)
        next "Sent the update to #{t['DisplayNumber']} but could NOT read the ticket back to " \
             'confirm it. Check in Gorelo before assuming it applied.'
      end

      after = { client: after_row['ClientId'], status: nested(after_row, 'Status', 'Id') }
      # Only the two fields this tool sets are verifiable - UpdatedByName is
      # write-only and does not come back on a GET.
      failed = []
      failed << 'ClientId' if payload.key?('ClientId') && after[:client].to_s != payload['ClientId'].to_s
      failed << 'StatusId' if payload.key?('StatusId') && after[:status].to_s != payload['StatusId'].to_s

      # Audit trail. Not a duplicate guard - unlike a comment, re-applying the
      # same status twice is harmless, so this records rather than refuses.
      api.record_write(api.fingerprint(t['Id'], payload.to_json),
                       "PATCH /v1/tickets/#{t['Id']} #{payload.to_json} " \
                       "→ #{failed.empty? ? 'applied' : "NO EFFECT on #{failed.join(',')}"}")

      out = ["#{t['DisplayNumber'] || "G-#{t['Number']}"}  #{t['Title']}"]
      if failed.empty?
        out << "Updated: #{intent.join('; ')}"
        out << "Verified by reading the ticket back: client=#{api.client_name(after[:client]) || after[:client]}, " \
               "status=#{nested(after_row, 'Status', 'Name')}"
      else
        out << "⚠ THE WRITE DID NOT TAKE EFFECT for: #{failed.join(', ')}"
        out << "Gorelo accepted the request and returned success, but reading the ticket back"
        out << "shows the value unchanged (client=#{before[:client].inspect}, status=#{before[:status].inspect})."
        out << ''
        out << 'The most likely cause is that the field name in the PATCH payload is wrong.'
        out << 'This API ignores unrecognised fields instead of rejecting them, so a wrong'
        out << 'name returns 200 and changes nothing. Check the PATCH request schema for'
        out << "/v1/tickets/{ticketId} in Gorelo's swagger and correct the payload in"
        out << "gorelo_update_ticket. Sent: #{payload.to_json}"
      end
      out.join("\n")
    end
  end

end
