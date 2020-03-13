# frozen_string_literal: true

# Preliminary support for unmerged MSCs (Matrix Spec Changes)
module MatrixSdk::Protocols::MSC
  def self.included(_)
    @msc = {}
  end

  def refresh_mscs
    @msc = {}
  end

  # Check if there's support for MSC2108 - Sync over Server Sent Events
  def msc2108?
    @msc[2108] ||= \
      begin
        request(:get, :client_r0, '/sync/sse', skip_auth: true, headers: { accept: 'text/event-stream' })
      rescue MatrixSdk::MatrixNotAuthorizedError # Returns 401 if implemented
        true
      rescue MatrixSdk::MatrixRequestError
        false
      end
  end

  # Sync over Server Sent Events - MSC2108
  #
  # @note With the default Ruby Net::HTTP server, body fragments are cached up to 16kB,
  #       which will result in large batches and delays if your filters trim a lot of data.
  #
  # @example Syncing over SSE
  #   @since = 'some token'
  #   api.msc2108_sync_sse(since: @since) do |data, event:, id:|
  #     if event == 'sync'
  #       handle(data) # data is the same as a normal sync response
  #       @since = id
  #     end
  #   end
  #
  # @see Protocols::CS#sync
  # @see https://github.com/matrix-org/matrix-doc/pull/2108/
  def msc2108_sync_sse(since: nil, **params, &on_data)
    raise ArgumentError, 'Must be given a block accepting two args - data and { event:, id: }' \
      unless on_data.is_a?(Proc) && on_data.arity == 2
    raise MatrixNotAuthorizedError unless access_token

    query = params.select do |k, _v|
      %i[filter full_state set_presence].include? k
    end
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    req = Net::HTTP::Get.new(homeserver.dup.tap do |u|
      u.path = api_to_path(:client_r0) + '/sync/sse'
      u.query = URI.encode_www_form(query)
    end)
    req['accept'] = 'text/event-stream'
    req['authorization'] = "Bearer #{access_token}"
    req['last-event-id'] = since if since

    # rubocop:disable Metrics/BlockLength
    thread = Thread.new do
      print_http(req)
      http.request req do |response|
        print_http(response, body: false)
        raise MatrixRequestError.new_by_code(JSON.parse(response.body, symbolize_names: true), response.code) unless response.is_a? Net::HTTPSuccess

        buffer = ''
        response.read_body do |chunk|
          buffer += chunk
          logger.debug "< MSC2108: Received #{chunk.length}B of data."

          while (index = buffer.index(/\r\n\r\n|\n\n/))
            stream = buffer.slice!(0..index)

            data = ''
            event = nil
            id = nil

            stream.split(/\r?\n/).each do |part|
              /^data:(.+)$/.match(part) do |m_data|
                data += "\n" unless data.empty?
                data += m_data[1].strip
              end
              /^event:(.+)$/.match(part) do |m_event|
                event = m_event[1].strip
              end
              /^id:(.+)$/.match(part) do |m_id|
                id = m_id[1].strip
              end
            end

            data = JSON.parse(data, symbolize_names: true)

            yield((MatrixSdk::Response.new self, data), event: event, id: id)
          end
        end
      end
    end
    # rubocop:enable Metrics/BlockLength

    thread.abort_on_exception = true
    thread.run

    thread
  end
end