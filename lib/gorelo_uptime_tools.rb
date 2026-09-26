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

  def register(server, api)
    list_uptime(server, api)
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
end
