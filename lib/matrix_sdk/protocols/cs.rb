module MatrixSdk::Protocols::CS
  # Gets the available client API versions
  # @return [Array]
  def client_api_versions
    @client_api_versions ||= request(:get, :client, '/versions').versions.tap do |vers|
      vers.instance_eval <<-'CODE', __FILE__, __LINE__ + 1
        def latest
          latest
        end
      CODE
    end
  end

  # Gets the list of available unstable client API features
  # @return [Array]
  def client_api_unstable_features
    @client_api_unstable_features ||= request(:get, :client, '/versions').unstable_features.tap do |vers|
      vers.instance_eval <<-'CODE', __FILE__, __LINE__ + 1
        def has?(feature)
          fetch(feature, nil)
        end
      CODE
    end
  end

  # Runs the client API /sync method
  # @param timeout [Numeric] (30.0) The timeout in seconds for the sync
  # @param params [Hash] The sync options to use
  # @option params [String] :since The value of the batch token to base the sync from
  # @option params [String,Hash] :filter The filter to use on the sync
  # @option params [Boolean] :full_state Should the sync include the full state
  # @option params [Boolean] :set_presence Should the sync set the user status to online
  # @return [Response]
  # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#get-matrix-client-r0-sync
  #      For more information on the parameters and what they mean
  def sync(timeout: 30.0, **params)
    query = {
      timeout: timeout
    }.merge(params).select do |k, _v|
      %i[since filter full_state set_presence].include? k
    end

    query[:timeout] = (query.fetch(:timeout, 30) * 1000).to_i
    query[:timeout] = params.delete(:timeout_ms).to_i if params.key? :timeout_ms
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    request(:get, :client_r0, '/sync', query: query)
  end

  # Registers a user using the client API /register endpoint
  #
  # @example Regular user registration and login
  #   api.register(username: 'example', password: 'NotARealPass')
  #   # => { user_id: '@example:matrix.org', access_token: '...', home_server: 'matrix.org', device_id: 'ABCD123' }
  #   api.whoami?
  #   # => { user_id: '@example:matrix.org' }
  #
  # @param kind [String,Symbol] ('user') The kind of registration to use
  # @param params [Hash] The registration information, all not handled by Ruby will be passed as JSON in the body
  # @option params [Boolean] :store_token (true) Should the resulting access token be stored for the API
  # @option params [Boolean] :store_device_id (store_token value) Should the resulting device ID be stored for the API
  # @return [Response]
  # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#post-matrix-client-r0-register
  #      For options that are permitted in this call
  def register(kind: 'user', **params)
    query = {}
    query[:kind] = kind
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    store_token = params.delete(:store_token) { !protocol?(:AS) }
    store_device_id = params.delete(:store_device_id) { store_token }

    request(:post, :client_r0, '/register', body: params, query: query).tap do |resp|
      @access_token = resp.token if resp.key?(:token) && store_token
      @device_id = resp.device_id if resp.key?(:device_id) && store_device_id
    end
  end

  # Logs in using the client API /login endpoint, and optionally stores the resulting access for API usage
  #
  # @example Logging in with username and password
  #   api.login(user: 'example', password: 'NotARealPass')
  #   # => { user_id: '@example:matrix.org', access_token: '...', home_server: 'matrix.org', device_id: 'ABCD123' }
  #   api.whoami?
  #   # => { user_id: '@example:matrix.org' }
  #
  # @example Advanced login, without storing details
  #   api.whoami?
  #   # => { user_id: '@example:matrix.org' }
  #   api.login(medium: 'email', address: 'someone@somewhere.net', password: '...', store_token: false)
  #   # => { user_id: '@someone:matrix.org', access_token: ...
  #   api.whoami?.user_id
  #   # => '@example:matrix.org'
  #
  # @param login_type [String] ('m.login.password') The type of login to attempt
  # @param params [Hash] The login information to use, along with options for said log in
  # @option params [Boolean] :store_token (true) Should the resulting access token be stored for the API
  # @option params [Boolean] :store_device_id (store_token value) Should the resulting device ID be stored for the API
  # @option params [String] :initial_device_display_name (USER_AGENT) The device display name to specify for this login attempt
  # @option params [String] :device_id The device ID to set on the login
  # @return [Response] A response hash with the parameters :user_id, :access_token, :home_server, and :device_id.
  # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#post-matrix-client-r0-login
  #      The Matrix Spec, for more information about the call and response
  def login(login_type: 'm.login.password', **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    options = {}
    options[:store_token] = params.delete(:store_token) { true }
    options[:store_device_id] = params.delete(:store_device_id) { options[:store_token] }

    data = {
      type: login_type,
      initial_device_display_name: params.delete(:initial_device_display_name) { MatrixSdk::Api::USER_AGENT }
    }.merge params
    data[:device_id] = device_id if device_id

    request(:post, :client_r0, '/login', body: data, query: query).tap do |resp|
      @access_token = resp.token if resp.key?(:token) && options[:store_token]
      @device_id = resp.device_id if resp.key?(:device_id) && options[:store_device_id]
    end
  end

  # Logs out the currently logged in user
  # @return [Response] An empty response if the logout was successful
  # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#post-matrix-client-r0-logout
  #      The Matrix Spec, for more information about the call and response
  def logout(**params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    request(:post, :client_r0, '/logout', query: query)
  end

  # Creates a new room
  # @param params [Hash] The room creation details
  # @option params [Symbol] :visibility (:public) The room visibility
  # @option params [String] :room_alias A room alias to apply on creation
  # @option params [Boolean] :invite Should the room be created invite-only
  # @return [Response] A response hash with ...
  # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#post-matrix-client-r0-createroom
  #      The Matrix Spec, for more information about the call and response
  def create_room(visibility: :public, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    content = {
      visibility: visibility
    }
    content[:room_alias_name] = params[:room_alias] if params[:room_alias]
    content[:invite] = [params[:invite]].flatten if params[:invite]

    request(:post, :client_r0, '/createRoom', content, query: query)
  end

  # Joins a room
  # @param id_or_alias [MXID,String] The room ID or Alias to join
  # @param params [Hash] Extra room join options
  # @option params [String[]] :server_name A list of servers to perform the join through
  # @return [Response] A response hash with the parameter :room_id
  # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#post-matrix-client-r0-join-roomidoralias
  #      The Matrix Spec, for more information about the call and response
  def join_room(id_or_alias, **params)
    query = {}
    query[:server_name] = params[:server_name] if params[:server_name]
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    # id_or_alias = MXID.new id_or_alias.to_s unless id_or_alias.is_a? MXID
    # raise ArgumentError, 'Not a room ID or alias' unless id_or_alias.room?

    id_or_alias = CGI.escape id_or_alias.to_s

    request(:post, :client_r0, "/join/#{id_or_alias}", query: query)
  end

  # Sends a state event to a room
  # @param room_id [MXID,String] The room ID to send the state event to
  # @param event_type [String] The event type to send
  # @param content [Hash] The contents of the state event
  # @param params [Hash] Options for the request
  # @option params [String] :state_key The state key of the event, if there is one
  # @return [Response] A response hash with the parameter :event_id
  # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#put-matrix-client-r0-rooms-roomid-state-eventtype-statekey
  #      https://matrix.org/docs/spec/client_server/r0.3.0.html#put-matrix-client-r0-rooms-roomid-state-eventtype
  #      The Matrix Spec, for more information about the call and response
  def send_state_event(room_id, event_type, content, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = CGI.escape room_id.to_s
    event_type = CGI.escape event_type.to_s
    state_key = CGI.escape params[:state_key].to_s if params.key? :state_key

    request(:put, :client_r0, "/rooms/#{room_id}/state/#{event_type}#{"/#{state_key}" unless state_key.nil?}", body: content, query: query)
  end

  # Sends a message event to a room
  # @param room_id [MXID,String] The room ID to send the message event to
  # @param event_type [String] The event type of the message
  # @param content [Hash] The contents of the message
  # @param params [Hash] Options for the request
  # @option params [Integer] :txn_id The ID of the transaction, or automatically generated
  # @return [Response] A response hash with the parameter :event_id
  # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#put-matrix-client-r0-rooms-roomid-send-eventtype-txnid
  #      The Matrix Spec, for more information about the call and response
  def send_message_event(room_id, event_type, content, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    txn_id = transaction_id
    txn_id = params.fetch(:txn_id, "#{txn_id}#{Time.now.to_i}")

    room_id = CGI.escape room_id.to_s
    event_type = CGI.escape event_type.to_s
    txn_id = CGI.escape txn_id.to_s

    request(:put, :client_r0, "/rooms/#{room_id}/send/#{event_type}/#{txn_id}", body: content, query: query)
  end

  # Redact an event in a room
  # @param room_id [MXID,String] The room ID to send the message event to
  # @param event_id [String] The event ID of the event to redact
  # @param params [Hash] Options for the request
  # @option params [String] :reason The reason for the redaction
  # @option params [Integer] :txn_id The ID of the transaction, or automatically generated
  # @return [Response] A response hash with the parameter :event_id
  # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#put-matrix-client-r0-rooms-roomid-redact-eventid-txnid
  #      The Matrix Spec, for more information about the call and response
  def redact_event(room_id, event_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    content = {}
    content[:reason] = params[:reason] if params[:reason]

    txn_id = transaction_id
    txn_id = params.fetch(:txn_id, "#{txn_id}#{Time.now.to_i}")

    room_id = CGI.escape room_id.to_s
    event_id = CGI.escape event_id.to_s
    txn_id = CGI.escape txn_id.to_s

    request(:put, :client_r0, "/rooms/#{room_id}/redact/#{event_id}/#{txn_id}", body: content, query: query)
  end

  # Send a content message to a room
  #
  # @example Sending an image to a room
  #   send_content('!abcd123:localhost',
  #                'mxc://localhost/1234567',
  #                'An image of a cat',
  #                'm.image',
  #                extra_information: {
  #                  h: 128,
  #                  w: 128,
  #                  mimetype: 'image/png',
  #                  size: 1024
  #                })
  #
  # @example Sending a file to a room
  #   send_content('!example:localhost',
  #                'mxc://localhost/fileurl',
  #                'Contract.pdf',
  #                'm.file',
  #                extra_content: {
  #                  filename: 'contract.pdf'
  #                },
  #                extra_information: {
  #                  mimetype: 'application/pdf',
  #                  size: 96674
  #                })
  #
  # @param room_id [MXID,String] The room ID to send the content to
  # @param url [URI,String] The URL to the content
  # @param name [String] The name of the content
  # @param msg_type [String] The message type of the content
  # @param params [Hash] Options for the request
  # @option params [Hash] :extra_information ({}) Extra information for the content
  # @option params [Hash] :extra_content Extra data to insert into the content hash
  # @return [Response] A response hash with the parameter :event_id
  # @see send_message_event For more information on the underlying call
  # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#m-image
  #      https://matrix.org/docs/spec/client_server/r0.3.0.html#m-file
  #      https://matrix.org/docs/spec/client_server/r0.3.0.html#m-video
  #      https://matrix.org/docs/spec/client_server/r0.3.0.html#m-audio
  #      The Matrix Spec, for more information about the call and response
  def send_content(room_id, url, name, msg_type, **params)
    content = {
      url: url,
      msgtype: msg_type,
      body: name,
      info: params.delete(:extra_information) { {} }
    }
    content.merge!(params.fetch(:extra_content)) if params.key? :extra_content

    send_message_event(room_id, 'm.room.message', content, params)
  end

  # Send a geographic location to a room
  #
  # @param room_id [MXID,String] The room ID to send the location to
  # @param geo_uri [URI,String] The geographical URI to send
  # @param name [String] The name of the location
  # @param params [Hash] Options for the request
  # @option params [Hash] :extra_information ({}) Extra information for the location
  # @option params [URI,String] :thumbnail_url The URL to a thumbnail of the location
  # @option params [Hash] :thumbnail_info Image information about the location thumbnail
  # @return [Response] A response hash with the parameter :event_id
  # @see send_message_event For more information on the underlying call
  # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#m-location
  #      The Matrix Spec, for more information about the call and response
  def send_location(room_id, geo_uri, name, **params)
    content = {
      geo_uri: geo_uri,
      msgtype: 'm.location',
      body: name,
      info: params.delete(:extra_information) { {} }
    }
    content[:info][:thumbnail_url] = params.delete(:thumbnail_url) if params.key? :thumbnail_url
    content[:info][:thumbnail_info] = params.delete(:thumbnail_info) if params.key? :thumbnail_info

    send_message_event(room_id, 'm.room.message', content, params)
  end

  # Send a plaintext message to a room
  #
  # @param room_id [MXID,String] The room ID to send the message to
  # @param message [String] The message to send
  # @param params [Hash] Options for the request
  # @option params [String] :msg_type ('m.text') The message type to send
  # @return [Response] A response hash with the parameter :event_id
  # @see send_message_event For more information on the underlying call
  # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#m-text
  #      The Matrix Spec, for more information about the call and response
  def send_message(room_id, message, **params)
    content = {
      msgtype: params.delete(:msg_type) { 'm.text' },
      body: message
    }
    send_message_event(room_id, 'm.room.message', content, params)
  end

  # Send a plaintext emote to a room
  #
  # @param room_id [MXID,String] The room ID to send the message to
  # @param emote [String] The emote to send
  # @param params [Hash] Options for the request
  # @option params [String] :msg_type ('m.emote') The message type to send
  # @return [Response] A response hash with the parameter :event_id
  # @see send_message_event For more information on the underlying call
  # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#m-emote
  #      The Matrix Spec, for more information about the call and response
  def send_emote(room_id, emote, **params)
    content = {
      msgtype: params.delete(:msg_type) { 'm.emote' },
      body: emote
    }
    send_message_event(room_id, 'm.room.message', content, params)
  end

  # Send a plaintext notice to a room
  #
  # @param room_id [MXID,String] The room ID to send the message to
  # @param notice [String] The notice to send
  # @param params [Hash] Options for the request
  # @option params [String] :msg_type ('m.notice') The message type to send
  # @return [Response] A response hash with the parameter :event_id
  # @see send_message_event For more information on the underlying call
  # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#m-notice
  #      The Matrix Spec, for more information about the call and response
  def send_notice(room_id, notice, **params)
    content = {
      msgtype: params.delete(:msg_type) { 'm.notice' },
      body: notice
    }
    send_message_event(room_id, 'm.room.message', content, params)
  end

  # Retrieve additional messages in a room
  #
  # @param room_id [MXID,String] The room ID to retrieve messages for
  # @param token [String] The token to start retrieving from, can be from a sync or from an earlier get_room_messages call
  # @param direction [:b,:f] The direction to retrieve messages
  # @param limit [Integer] (10) The limit of messages to retrieve
  # @param params [Hash] Additional options for the request
  # @option params [String] :to A token to limit retrieval to
  # @option params [String] :filter A filter to limit the retrieval to
  # @return [Response] A response hash with the message information containing :start, :end, and :chunk fields
  # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#get-matrix-client-r0-rooms-roomid-messages
  #      The Matrix Spec, for more information about the call and response
  def get_room_messages(room_id, token, direction, limit: 10, **params)
    query = {
      roomId: room_id,
      from: token,
      dir: direction,
      limit: limit
    }
    query[:to] = params[:to] if params.key? :to
    query[:filter] = params.fetch(:filter) if params.key? :filter
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = CGI.escape room_id.to_s

    request(:get, :client_r0, "/rooms/#{room_id}/messages", query: query)
  end

  # Reads the latest instance of a room state event
  #
  # @param room_id [MXID,String] The room ID to read from
  # @param state_type [String] The state type to read
  # @return [Response] A response hash with the contents of the state event
  # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#get-matrix-client-r0-rooms-roomid-state-eventtype
  #      The Matrix Spec, for more information about the call and response
  def get_room_state(room_id, state_type, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = CGI.escape room_id.to_s
    state_type = CGI.escape state_type.to_s

    request(:get, :client_r0, "/rooms/#{room_id}/state/#{state_type}", query: query)
  end

  # Gets the display name of a room
  #
  # @param room_id [MXID,String] The room ID to look up
  # @return [Response] A response hash with the parameter :name
  # @see get_room_state
  # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#m-room-name
  #      The Matrix Spec, for more information about the event and data
  def get_room_name(room_id, **params)
    get_room_state(room_id, 'm.room.name', params)
  end

  def set_room_name(room_id, name, **params)
    content = {
      name: name
    }
    send_state_event(room_id, 'm.room.name', content, params)
  end

  def get_room_topic(room_id, **params)
    get_room_state(room_id, 'm.room.topic', params)
  end

  def set_room_topic(room_id, topic, **params)
    content = {
      topic: topic
    }
    send_state_event(room_id, 'm.room.topic', content, params)
  end

  def get_power_levels(room_id, **params)
    get_room_state(room_id, 'm.room.power_levels', params)
  end

  def set_power_levels(room_id, content, **params)
    content[:events] = {} unless content.key? :events
    send_state_event(room_id, 'm.room.power_levels', content, params)
  end

  def leave_room(room_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = CGI.escape room_id.to_s

    request(:post, :client_r0, "/rooms/#{room_id}/leave", query: query)
  end

  def forget_room(room_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = CGI.escape room_id.to_s

    request(:post, :client_r0, "/rooms/#{room_id}/forget", query: query)
  end

  def invite_user(room_id, user_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    content = {
      user_id: user_id
    }

    room_id = CGI.escape room_id.to_s

    request(:post, :client_r0, "/rooms/#{room_id}/invite", body: content, query: query)
  end

  def kick_user(room_id, user_id, **params)
    set_membership(room_id, user_id, 'leave', params)
  end

  def get_membership(room_id, user_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = CGI.escape room_id.to_s
    user_id = CGI.escape user_id.to_s

    request(:get, :client_r0, "/rooms/#{room_id}/state/m.room.member/#{user_id}", query: query)
  end

  def set_membership(room_id, user_id, membership, reason: '', **params)
    content = {
      membership: membership,
      reason: reason
    }
    content[:displayname] = params.delete(:displayname) if params.key? :displayname
    content[:avatar_url] = params.delete(:avatar_url) if params.key? :avatar_url

    send_state_event(room_id, 'm.room.member', content, params.merge(state_key: user_id))
  end

  def ban_user(room_id, user_id, reason: '', **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    content = {
      user_id: user_id,
      reason: reason
    }
    room_id = CGI.escape room_id.to_s

    request(:post, :client_r0, "/rooms/#{room_id}/ban", body: content, query: query)
  end

  def unban_user(room_id, user_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    content = {
      user_id: user_id
    }
    room_id = CGI.escape room_id.to_s

    request(:post, :client_r0, "/rooms/#{room_id}/unban", body: content, query: query)
  end

  def get_user_tags(user_id, room_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = CGI.escape room_id.to_s
    user_id = CGI.escape user_id.to_s

    request(:get, :client_r0, "/user/#{user_id}/rooms/#{room_id}/tags", query: query)
  end

  def remove_user_tag(user_id, room_id, tag, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = CGI.escape room_id.to_s
    user_id = CGI.escape user_id.to_s
    tag = CGI.escape tag.to_s

    request(:delete, :client_r0, "/user/#{user_id}/rooms/#{room_id}/tags/#{tag}", query: query)
  end

  def add_user_tag(user_id, room_id, tag, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    if params[:body]
      content = params[:body]
    else
      content = {}
      content[:order] = params[:order] if params.key? :order
    end

    room_id = CGI.escape room_id.to_s
    user_id = CGI.escape user_id.to_s
    tag = CGI.escape tag.to_s

    request(:put, :client_r0, "/user/#{user_id}/rooms/#{room_id}/tags/#{tag}", body: content, query: query)
  end

  def get_account_data(user_id, type_key, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    user_id = CGI.escape user_id.to_s
    type_key = CGI.escape type_key.to_s

    request(:get, :client_r0, "/user/#{user_id}/account_data/#{type_key}", query: query)
  end

  def set_account_data(user_id, type_key, account_data, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    user_id = CGI.escape user_id.to_s
    type_key = CGI.escape type_key.to_s

    request(:put, :client_r0, "/user/#{user_id}/account_data/#{type_key}", body: account_data, query: query)
  end

  def get_room_account_data(user_id, room_id, type_key, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    user_id = CGI.escape user_id.to_s
    room_id = CGI.escape room_id.to_s
    type_key = CGI.escape type_key.to_s

    request(:get, :client_r0, "/user/#{user_id}/rooms/#{room_id}/account_data/#{type_key}", query: query)
  end

  def set_room_account_data(user_id, room_id, type_key, account_data, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    user_id = CGI.escape user_id.to_s
    room_id = CGI.escape room_id.to_s
    type_key = CGI.escape type_key.to_s

    request(:put, :client_r0, "/user/#{user_id}/rooms/#{room_id}/account_data/#{type_key}", body: account_data, query: query)
  end

  def get_filter(user_id, filter_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    user_id = CGI.escape user_id.to_s
    filter_id = CGI.escape filter_id.to_s

    request(:get, :client_r0, "/user/#{user_id}/filter/#{filter_id}", query: query)
  end

  def create_filter(user_id, filter_params, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    user_id = CGI.escape user_id.to_s

    request(:post, :client_r0, "/user/#{user_id}/filter", body: filter_params, query: query)
  end

  def media_upload(content, content_type, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    request(:post, :media_r0, '/upload', body: content, headers: { 'content-type' => content_type }, query: query)
  end

  def get_display_name(user_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    user_id = CGI.escape user_id.to_s

    request(:get, :client_r0, "/profile/#{user_id}/displayname", query: query)
  end

  def set_display_name(user_id, display_name, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    content = {
      displayname: display_name
    }

    user_id = CGI.escape user_id.to_s

    request(:put, :client_r0, "/profile/#{user_id}/displayname", body: content, query: query)
  end

  def get_avatar_url(user_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    user_id = CGI.escape user_id.to_s

    request(:get, :client_r0, "/profile/#{user_id}/avatar_url", query: query)
  end

  def set_avatar_url(user_id, url, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    content = {
      avatar_url: url
    }

    user_id = CGI.escape user_id.to_s

    request(:put, :client_r0, "/profile/#{user_id}/avatar_url", body: content, query: query)
  end

  def get_download_url(mxcurl, **_params)
    mxcurl = URI.parse(mxcurl.to_s) unless mxcurl.is_a? URI
    raise 'Not a mxc:// URL' unless mxcurl.is_a? URI::MATRIX

    homeserver.dup.tap do |u|
      full_path = CGI.escape mxcurl.full_path.to_s
      u.path = "/_matrix/media/r0/download/#{full_path}"
    end
  end

  def get_room_id(room_alias, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_alias = CGI.escape room_alias.to_s

    request(:get, :client_r0, "/directory/room/#{room_alias}", query: query)
  end

  def set_room_alias(room_id, room_alias, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    content = {
      room_id: room_id
    }
    room_alias = CGI.escape room_alias.to_s

    request(:put, :client_r0, "/directory/room/#{room_alias}", body: content, query: query)
  end

  def remove_room_alias(room_alias, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_alias = CGI.escape room_alias.to_s

    request(:delete, :client_r0, "/directory/room/#{room_alias}", query: query)
  end

  def get_room_members(room_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = CGI.escape room_id.to_s

    request(:get, :client_r0, "/rooms/#{room_id}/members", query: query)
  end

  def set_join_rule(room_id, join_rule, **params)
    content = {
      join_rule: join_rule
    }

    send_state_event(room_id, 'm.room.join_rules', params.merge(content))
  end

  def set_guest_access(room_id, guest_access, **params)
    # raise ArgumentError, '`guest_access` must be one of [:can_join, :forbidden]' unless %i[can_join forbidden].include? guest_access
    content = {
      guest_access: guest_access
    }

    send_state_event(room_id, 'm.room.guest_access', params.merge(content))
  end

  def whoami?(**params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    request(:get, :client_r0, '/account/whoami', query: query)
  end
end