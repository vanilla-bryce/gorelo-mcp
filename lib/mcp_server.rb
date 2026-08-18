# frozen_string_literal: true

# A minimal MCP server over stdio, in plain Ruby stdlib.
#
# WHY NO GEM: the stdio surface of MCP is five methods. Implementing them
# directly means no bundler, no gem install, no version drift on a Windows
# machine, and no dependency that can break the one tool you actually use.
# If this ever needs HTTP transport, OAuth, or resources, swap this file for
# the official `mcp` gem - the tool definitions in gorelo_tools.rb are
# deliberately kept independent of it.
#
# THE ONE RULE: stdout carries the protocol. Nothing else may ever be written
# to it. All diagnostics go to stderr. A single stray `puts` corrupts the
# stream and the client silently disconnects.

require 'json'

module McpStdio
  PROTOCOL_VERSION = '2025-06-18'

  # Versions we know how to speak. If the client asks for something else we
  # answer with our own and let it decide - that is what the spec requires,
  # and it is why this keeps working when the client updates.
  KNOWN_VERSIONS = %w[2025-06-18 2025-03-26 2024-11-05 2026-07-28].freeze

  class Tool
    attr_reader :name, :title, :description, :input_schema, :read_only, :handler

    def initialize(name:, title:, description:, input_schema:, read_only: true, &handler)
      @name         = name
      @title        = title
      @description  = description
      @input_schema = input_schema
      @read_only    = read_only
      @handler      = handler
    end

    def to_descriptor
      {
        name:        name,
        title:       title,
        description: description,
        inputSchema: input_schema,
        annotations: {
          title:           title,
          readOnlyHint:    read_only,
          destructiveHint: false,
          idempotentHint:  read_only,
          openWorldHint:   true
        }
      }
    end
  end

  class Server
    def initialize(name:, version:, instructions: nil)
      @name         = name
      @version      = version
      @instructions = instructions
      @tools        = {}
    end

    def tool(name:, title:, description:, input_schema:, read_only: true, &handler)
      @tools[name] = Tool.new(
        name: name, title: title, description: description,
        input_schema: input_schema, read_only: read_only, &handler
      )
    end

    def log(message)
      warn "[gorelo-mcp] #{message}"
    end

    def run(input: $stdin, output: $stdout)
      # Windows specifics, all of which bite over a pipe:
      #   binmode stops \n being rewritten to \r\n, which would corrupt the
      #     line framing this protocol depends on;
      #   stdin is read as UTF-8 so JSON.parse never sees binary strings;
      #   stderr is set to UTF-8 so a diagnostic containing a non-ASCII
      #     character cannot raise inside the logger.
      output.binmode
      output.sync = true
      begin
        input.set_encoding(Encoding::UTF_8)
        $stderr.set_encoding(Encoding::UTF_8)
      rescue StandardError
        nil
      end

      log "ready - #{@tools.size} tools"

      while (line = input.gets)
        line = line.strip
        next if line.empty?

        begin
          message = JSON.parse(line)
        rescue JSON::ParserError => e
          log "unparseable line ignored: #{e.message}"
          next
        end

        reply = dispatch(message)
        next unless reply # notifications carry no id and get no response

        # ascii_only escapes every non-ASCII character to \uXXXX, so the bytes
        # on the wire are pure ASCII regardless of the machine's code page.
        # The client decodes them back to the original text.
        output.write("#{JSON.generate(reply, ascii_only: true)}\n")
      end

      log 'stdin closed - exiting'
    end

    private

    def dispatch(message)
      id     = message['id']
      method = message['method']
      params = message['params'] || {}

      # A response or notification from the client: nothing to answer.
      return nil if method.nil?

      case method
      when 'initialize'                then ok(id, initialize_result(params))
      when 'notifications/initialized' then nil
      when 'ping'                      then ok(id, {})
      when 'tools/list'                then ok(id, { tools: @tools.values.map(&:to_descriptor) })
      when 'tools/call'                then ok(id, call_tool(params))
      when 'resources/list'            then ok(id, { resources: [] })
      when 'prompts/list'              then ok(id, { prompts: [] })
      else
        return nil if id.nil? # unknown notification - stay quiet
        err(id, -32601, "Method not found: #{method}")
      end
    rescue StandardError => e
      log "internal error on #{method}: #{e.class}: #{e.message}"
      log e.backtrace.first(5).join("\n") if e.backtrace
      id.nil? ? nil : err(id, -32603, "Internal error: #{e.message}")
    end

    def initialize_result(params)
      asked = params['protocolVersion']
      speak = KNOWN_VERSIONS.include?(asked) ? asked : PROTOCOL_VERSION
      log "client #{params.dig('clientInfo', 'name') || 'unknown'} asked for #{asked.inspect}, speaking #{speak}"

      result = {
        protocolVersion: speak,
        capabilities:    { tools: { listChanged: false } },
        serverInfo:      { name: @name, version: @version }
      }
      result[:instructions] = @instructions if @instructions
      result
    end

    # Tool failures are NOT JSON-RPC errors. They come back as normal results
    # with isError set, so the model can read the message and try something
    # else instead of the whole call blowing up.
    def call_tool(params)
      name = params['name']
      args = params['arguments'] || {}
      tool = @tools[name]

      return text_result("Unknown tool: #{name}", is_error: true) if tool.nil?

      begin
        text_result(tool.handler.call(args).to_s)
      rescue StandardError => e
        log "tool #{name} failed: #{e.class}: #{e.message}"
        text_result("#{e.class}: #{e.message}", is_error: true)
      end
    end

    def text_result(text, is_error: false)
      { content: [{ type: 'text', text: text }], isError: is_error }
    end

    def ok(id, result)
      { jsonrpc: '2.0', id: id, result: result }
    end

    def err(id, code, message)
      { jsonrpc: '2.0', id: id, error: { code: code, message: message } }
    end
  end
end
