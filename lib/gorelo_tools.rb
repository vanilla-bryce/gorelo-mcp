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
    add_ticket_comment(server, api)
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
          search:     { type: 'string', description: 'Case-insensitive substring match on the ticket title.' },
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

      if args['search'] && !args['search'].to_s.empty?
        needle = args['search'].to_s.downcase
        selected.select! { |t| t['Title'].to_s.downcase.include?(needle) }
      end

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
      out << 'Awaiting client: YES - Gorelo believes the ball is in their court' if t['IsAwaitingClient']
      out << "MERGED into #{t['MergedIntoTicketId']}" if t['IsMerged']
      out << "Last update #{nested(t, 'LastUpdate', 'UpdateType')}: #{nested(t, 'LastUpdate', 'Summary')}"
      out << "Ticket id   #{t['Id']}"

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
        agents = api.get_all('/v1/assets/agents')
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
      description: 'Managed agents/devices. Optionally narrowed to a client or a name fragment, ' \
                   'or filtered to devices not seen for N days - the fastest way to find agents ' \
                   'still billing for a client who left.',
      input_schema: {
        type: 'object',
        properties: {
          client:        { type: 'string', description: 'Client name fragment or id.' },
          search:        { type: 'string', description: 'Device name fragment.' },
          stale_days:    { type: 'integer', description: 'Only devices not seen for at least this many days.' },
          limit:         { type: 'integer', description: 'Default 50.' }
        },
        additionalProperties: false
      }
    ) do |args|
      limit  = (args['limit'] || 50).to_i.clamp(1, 500)
      agents = api.get_all('/v1/assets/agents')
      rows   = agents

      if args['client'] && !args['client'].to_s.empty?
        matched = api.resolve_clients(args['client'])
        next "No client matches #{args['client'].inspect}." if matched.empty?

        want = matched.map { |c| c['Id'].to_s }
        rows = rows.select do |a|
          [a['ClientId'], nested(a, 'Client', 'Id'), a['CompanyId'], a['OrganizationId']]
            .compact.map(&:to_s).any? { |v| want.include?(v) }
        end
      end

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

      out = ["#{rows.size} of #{agents.size} devices match.", '']
      out << "#{pad('Device', 26)}#{pad('Client', 26)}#{pad('OS', 28)}last seen"
      out << ('-' * 92)
      rows.first(limit).each do |a|
        cid = a['ClientId'] || nested(a, 'Client', 'Id') || a['CompanyId']
        out << "#{pad(a['Name'] || a['HostName'] || a['ComputerName'] || a['Id'], 26)}" \
               "#{pad(api.client_name(cid) || cid, 26)}" \
               "#{pad(a['OperatingSystem'] || nested(a, 'Os', 'Name'), 28)}#{age(seen_of.call(a))} ago"
      end
      out << "#{rows.size - limit} more not shown." if rows.size > limit
      out.join("\n")
    end
  end

  # ---- 7. add ticket comment (the only write) -----------------------------

  COMMENT_POST_PATHS = %w[comments notes conversations].freeze

  def add_ticket_comment(server, api)
    server.tool(
      name:  'gorelo_add_ticket_comment',
      title: 'Add a comment to a Gorelo ticket',
      description: <<~TEXT,
        Post a comment on a ticket. This is the ONLY tool that writes anything.

        Safety:
          - disabled unless GORELO_ALLOW_WRITES=true
          - `confirm: true` is required on every call
          - defaults to an INTERNAL note; set visibility "client" deliberately, as that
            may email the client
          - identical comments on the same ticket within 24 hours are refused, so a
            retried call cannot post twice
      TEXT
      read_only: false,
      input_schema: {
        type: 'object',
        properties: {
          ticket:     { type: 'string', description: 'Ticket number such as G-13933, or a ticket id.' },
          body:       { type: 'string', description: 'The comment text.' },
          visibility: { type: 'string', enum: %w[internal client], description: 'Default "internal".' },
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

      t = find_ticket(api, args['ticket'])
      next "Could not find ticket #{args['ticket']} - nothing was posted." unless t

      key = api.fingerprint(t['Id'], args['body'].strip)
      if api.write_fingerprint_seen?(key)
        next "Refused: an identical comment was already posted to #{t['DisplayNumber']} in the " \
             'last 24 hours. Nothing was sent.'
      end

      payload = {
        'Body'       => args['body'],
        'Text'       => args['body'],
        'IsInternal' => internal,
        'IsPrivate'  => internal
      }

      posted = nil
      errors = []
      COMMENT_POST_PATHS.each do |seg|
        begin
          api.post("/v1/tickets/#{t['Id']}/#{seg}", payload)
          posted = seg
          break
        rescue Gorelo::AuthError
          raise
        rescue Gorelo::Error => e
          errors << "#{seg}: #{e.message}"
        end
      end

      unless posted
        next "Could not post. Tried #{COMMENT_POST_PATHS.join(', ')}:\n  " + errors.join("\n  ") +
             "\nUse gorelo_api_probe to confirm the write path before retrying."
      end

      api.record_write(key, "#{t['DisplayNumber']} via #{posted} (#{visibility})")
      "Posted #{internal ? 'an internal' : 'a CLIENT-VISIBLE'} comment to #{t['DisplayNumber']} - #{t['Title']} " \
        "(via /v1/tickets/{id}/#{posted})."
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
end
