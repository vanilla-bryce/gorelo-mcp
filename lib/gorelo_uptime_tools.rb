# frozen_string_literal: true

# Uptime checks (Gorelo, 25 September 2026): what is being watched, and which
# checks are silenced by a maintenance window - including windows that never
# end, which is how a real outage goes unnoticed.

require 'time'
require_relative 'gorelo'
require_relative 'gorelo_tools'

module GoreloUptimeTools
  module_function

  def pad(...)    = GoreloTools.pad(...)
  def clip(...)   = GoreloTools.clip(...)
  def nested(...) = GoreloTools.nested(...)

  UPTIME_TYPE       = { 'icmp' => 1, 'http' => 2, 'tcp' => 3 }.freeze
  STALE_WINDOW_DAYS = 7
  GUID               = Gorelo::Client::GUID
  MAX_WINDOW_MINUTES = 10_080 # a week. Longer should be a decision made in Gorelo.
  ATTRIBUTION        = '[Gorelo MCP] '

  def register(server, api)
    list_uptime(server, api)
    set_uptime_maintenance(server, api)
  end

  def target(check)
    t = check['Target'] || {}
    return t['Url'] unless t['Url'].to_s.strip.empty?

    t['Port'] ? "#{t['Ip']}:#{t['Port']}" : t['Ip'].to_s
  end

  # [in_maintenance, text, flags]. A duration of 0 means the window never ends.
  def maintenance(check, now = Time.now.utc)
    m = check['MaintenanceMode'] || {}
    return [false, '-', []] unless m['Enabled']

    start  = begin
      Time.parse(m['StartDateTime'].to_s).utc
    rescue ArgumentError
      nil
    end
    reason = m['Reason'].to_s.strip.empty? ? 'no reason given' : m['Reason'].to_s.strip
    flags  = []

    if m['DurationInMinutes'].to_i.zero?
      text = "NEVER EXPIRES (#{reason})"
      flags << 'in maintenance with NO END - it stays silenced until someone ends it'
    else
      ends = start && start + (m['DurationInMinutes'].to_i * 60)
      text = if ends && ends < now
               "ENDED #{ends.strftime('%Y-%m-%d %H:%M UTC')} but still marked enabled (#{reason})"
             else
               "until #{ends ? ends.strftime('%Y-%m-%d %H:%M UTC') : '?'} (#{reason})"
             end
    end
    if start && start < now - (STALE_WINDOW_DAYS * 86_400)
      flags << "in maintenance since #{start.strftime('%Y-%m-%d')} - more than #{STALE_WINDOW_DAYS} days"
    end
    [true, text, flags]
  end

  def list_uptime(server, api)
    server.tool(
      name:  'gorelo_list_uptime',
      title: 'List Gorelo uptime checks',
      description: <<~TEXT,
        Uptime checks: what each one watches (ICMP host, HTTP URL or TCP port), for which
        client, its current status, and whether it is in a MAINTENANCE WINDOW - with when that
        window ends. A check in maintenance raises no alerts.

        Flagged by name: windows that never expire (duration 0) and windows that started more
        than 7 days ago. Both are how a real outage goes unnoticed.
      TEXT
      input_schema: {
        type: 'object',
        properties: {
          client:      { type: 'string', description: 'Client name fragment or id. Comma-separate several.' },
          type:        { type: 'string', enum: %w[all icmp http tcp], description: 'Default "all".' },
          query:       { type: 'string', description: 'Keyword matched against the check description.' },
          maintenance: { type: 'string', enum: %w[all only exclude], description: '"only": checks in maintenance. "exclude": checks not in it. Default "all".' },
          limit:       { type: 'integer', description: 'Default 100.' }
        },
        additionalProperties: false
      }
    ) do |args|
      limit = (args['limit'] || 100).to_i.clamp(1, 1000)
      query = {}
      scope = []

      unless args['client'].to_s.strip.empty?
        matched = api.resolve_clients(args['client'])
        next "No client matches #{args['client'].inspect}." if matched.empty?

        query['ClientIds'] = matched.map { |c| c['Id'] }.join(',')
        scope << "client=#{matched.map { |c| c['Name'] }.first(3).join(' + ')}"
      end

      type = args['type'].to_s.downcase
      if UPTIME_TYPE.key?(type)
        query['TypeIds'] = UPTIME_TYPE[type]
        scope << type.upcase
      end

      unless args['query'].to_s.strip.empty?
        query['Query'] = args['query'].to_s.strip[0, 200]
        scope << "matching #{args['query'].to_s.strip.inspect}"
      end

      all  = api.get_all('/v1/uptime', query)
      info = all.to_h { |c| [c['Id'], maintenance(c)] }
      rows = case args['maintenance'].to_s.downcase
             when 'only'
               scope << 'in maintenance'
               all.select { |c| info[c['Id']][0] }
             when 'exclude'
               scope << 'not in maintenance'
               all.reject { |c| info[c['Id']][0] }
             else
               all
             end

      scope_text = scope.empty? ? '' : " - #{scope.join(', ')}"
      next "No uptime checks#{scope_text}. #{all.size} matched before the maintenance filter." if rows.empty?

      in_maint = all.count { |c| info[c['Id']][0] }
      out = ["#{rows.size} uptime check(s)#{scope_text}. #{in_maint} of #{all.size} in maintenance."]
      out << ''
      out << "#{pad('Check', 32)}#{pad('Client', 22)}#{pad('Type', 6)}#{pad('Target', 34)}" \
             "#{pad('Status', 10)}Maintenance"
      out << ('-' * 134)
      rows.first(limit).each do |c|
        client = c['ClientId'] ? (api.client_name(c['ClientId']) || "client #{c['ClientId']}") : '(no client)'
        out << "#{pad(c['Description'] || c['Id'], 32)}#{pad(client, 22)}" \
               "#{pad(nested(c, 'Type', 'Name'), 6)}#{pad(target(c), 34)}" \
               "#{pad(nested(c, 'Status', 'Name'), 10)}#{info[c['Id']][1]}"
      end
      out << "#{rows.size - limit} more not shown - raise limit." if rows.size > limit

      flagged = rows.flat_map { |c| info[c['Id']][2].map { |f| "#{c['Description'] || c['Id']}: #{f}" } }
      unless flagged.empty?
        out << ''
        flagged.each { |f| out << "⚠ #{f}" }
      end
      out.join("\n")
    end
  end

  # One check by id, or by a description fragment matching EXACTLY one.
  def find_check(api, ref)
    ref = ref.to_s.strip
    return [nil, 'Give an uptime check id or a fragment of its description.'] if ref.empty?
    return [api.get("/v1/uptime/#{ref}")['Data'], nil] if ref.match?(GUID)

    hits = api.get_all('/v1/uptime', { 'Query' => ref[0, 200] })
              .select { |c| c['Description'].to_s.downcase.include?(ref.downcase) }
    return [nil, "No uptime check description contains #{ref.inspect}."] if hits.empty?
    if hits.size > 1
      return [nil, "#{hits.size} uptime checks match #{ref.inspect}: " \
                   "#{hits.first(10).map { |c| c['Description'] }.join('; ')}. Narrow it, or give the id."]
    end

    [hits.first, nil]
  end

  def set_uptime_maintenance(server, api)
    server.tool(
      name:  'gorelo_set_uptime_maintenance',
      title: 'Start or end maintenance on a Gorelo uptime check',
      description: <<~TEXT,
        Starts or ends a maintenance window on ONE uptime check. A check in maintenance raises
        no alerts, so a window nobody ends hides real outages.

        Safety:
          - disabled unless GORELO_ALLOW_WRITES=true; `confirm: true` required
          - sends ONLY MaintenanceMode - never the check's target, type, client or tags
          - `start` needs a reason and a duration in minutes (1-10080). A window that never
            expires needs `indefinite: true`; it never comes from a default or a zero
          - the reason is prefixed "[Gorelo MCP]", because the API records no author
          - the check is read back to confirm the change took effect
      TEXT
      read_only: false,
      input_schema: {
        type: 'object',
        properties: {
          check:      { type: 'string', description: 'Uptime check id, or a fragment of its description matching exactly one check.' },
          action:     { type: 'string', enum: %w[start end] },
          minutes:    { type: 'integer', description: 'Length of the window, 1-10080. Required to start, unless indefinite.' },
          indefinite: { type: 'boolean', description: 'true: the window never expires. Only to start, and only on purpose.' },
          reason:     { type: 'string', description: 'Why. Required to start.' },
          confirm:    { type: 'boolean', description: 'Must be true. Nothing is written without it.' }
        },
        required: %w[check action confirm],
        additionalProperties: false
      }
    ) do |args|
      next 'Writes are disabled. Set GORELO_ALLOW_WRITES=true in .env and restart.' unless api.writes_allowed?
      next 'Refused: confirm must be true. Nothing was written.' unless args['confirm'] == true

      action = args['action'].to_s
      next 'Refused: action must be "start" or "end". Nothing was written.' unless %w[start end].include?(action)

      if action == 'start'
        reason = args['reason'].to_s.strip
        next 'Refused: a reason is required to start maintenance. Nothing was written.' if reason.empty?

        if args['indefinite'] == true
          unless args['minutes'].nil? || args['minutes'].to_i.zero?
            next 'Refused: give minutes OR indefinite: true, not both. Nothing was written.'
          end

          minutes = 0
        else
          minutes = args['minutes'].to_i
          unless minutes.between?(1, MAX_WINDOW_MINUTES)
            next "Refused: minutes must be 1-#{MAX_WINDOW_MINUTES}. A window that never ends needs " \
                 'indefinite: true. Nothing was written.'
          end
        end
        mode = { 'Enabled' => true, 'StartDateTime' => Time.now.utc.iso8601,
                 'DurationInMinutes' => minutes, 'Reason' => "#{ATTRIBUTION}#{reason}" }
      else
        mode = { 'Enabled' => false }
      end

      check, why = find_check(api, args['check'])
      next "#{why} Nothing was written." unless check

      label  = check['Description'] || check['Id']
      before = check['MaintenanceMode'] || {}
      next "#{label} is not in maintenance. Nothing was written." if action == 'end' && !before['Enabled']

      payload = { 'MaintenanceMode' => mode }
      begin
        api.patch("/v1/uptime/#{check['Id']}", payload)
      rescue Gorelo::Error => e
        next "Gorelo refused the change to #{label}: #{e.message}"
      end

      after = begin
        api.get("/v1/uptime/#{check['Id']}")['Data']
      rescue Gorelo::Error
        nil
      end
      unless after.is_a?(Hash)
        next "Sent the change to #{label} but could NOT read the check back to confirm it. Check in Gorelo."
      end

      now_mode = after['MaintenanceMode'] || {}
      took = now_mode['Enabled'] == mode['Enabled'] &&
             (action == 'end' || now_mode['DurationInMinutes'].to_i == mode['DurationInMinutes'])

      # Audit trail, as for gorelo_update_ticket. Re-applying a window is
      # harmless, so this records rather than refuses.
      api.record_write(api.fingerprint(check['Id'], payload.to_json),
                       "PATCH /v1/uptime/#{check['Id']} #{payload.to_json} → #{took ? 'applied' : 'NO EFFECT'}")

      unless took
        next "⚠ DID NOT TAKE EFFECT. Gorelo accepted the change to #{label}, but reading it back shows " \
             "MaintenanceMode #{now_mode.to_json}. The API ignores fields it doesn't recognise, so " \
             "the payload may be wrong. Sent: #{payload.to_json}"
      end

      if action == 'end'
        "Ended maintenance on #{label}. Verified by reading it back: alerts are live again."
      else
        had  = before['Enabled'] ? "It was already in maintenance (#{maintenance(check)[1]}); that window was replaced. " : ''
        text = "Started maintenance on #{label}: #{maintenance(after)[1]}. #{had}Verified by reading it back."
        text += "\n⚠ This window NEVER EXPIRES. The check raises no alerts until someone ends it." if mode['DurationInMinutes'].zero?
        text
      end
    end
  end
end
