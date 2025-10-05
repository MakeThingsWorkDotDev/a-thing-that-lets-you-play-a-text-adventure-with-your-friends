require 'sinatra'
require 'faye/websocket'
require 'json'
require 'sequel'
require 'securerandom'
require 'bcrypt'

set :sockets, {}  # Changed to hash to namespace by room_id
enable :sessions

require_relative 'initializers/db.rb'

# WebSocket ping thread - keeps connections alive
Thread.new do
  loop do
    sleep 5
    settings.sockets.each do |room_id, sockets|
      sockets.each do |socket|
        begin
          socket.send(JSON.generate({type: "ping", message: Time.now.to_i})) if socket
        rescue => e
          puts "Ping error: #{e.message}"
        end
      end
    end
  end
end

# Helper methods
def current_user
  return nil unless session[:user_id]

  DB[:users].where(id: session[:user_id]).first
end

def render_message(user_id, username, message, room_id, is_own: false)
  room = DB[:rooms].where(id: room_id).first
  user = DB[:users].where(id: user_id).first

  # Determine if this is a GM message
  is_gm = user_id == room[:game_master_id]

  template = is_gm ? :'messages/_gm_message' : :'messages/_player_message'

  erb template, locals: { username: username, message: message, is_own: is_own }, layout: false
end

def require_auth
  redirect '/login' unless current_user
end

def is_admin_setup_complete?
  result = DB[:admins].first
  result && result[:is_setup_complete]
end

def authenticate_user(username, password)
  user = DB[:users].where(username: username).first
  return nil unless user

  BCrypt::Password.new(user[:password_digest]) == password ? user : nil
end

def create_user(username, password, is_admin = false, magic_link_id = nil)
  password_digest = BCrypt::Password.create(password)

  user_id = DB[:users].insert(
    username: username,
    password_digest: password_digest,
    is_admin: is_admin,
    magic_link_id: magic_link_id
  )

  # Store user ID in Sinatra session
  session[:user_id] = user_id
  user_id
end

# Routes

# Main chat interface - requires authentication
get '/' do
  redirect '/setup' unless is_admin_setup_complete?

  user = current_user
  redirect '/login' unless user

  @username = user[:username]
  @is_admin = user[:is_admin]

  # Get rooms user has access to (through user_rooms table)
  @rooms = DB[:rooms]
    .join(:user_rooms, room_id: :id)
    .where(user_id: user[:id])
    .select(Sequel[:rooms][:id], Sequel[:rooms][:name], Sequel[:rooms][:description])
    .all

  erb :index
end

# Setup route - first user becomes admin
get '/setup' do
  # If admin is already set up, redirect to login or handle magic link
  if is_admin_setup_complete?
    token = params[:token]
    if token
      # Validate magic link
      link = DB[:magic_links].where(
        token: token,
        is_active: true
      ).where(
        Sequel.|(
          { expires_at: nil },
          Sequel.expr(:expires_at) > Sequel::CURRENT_TIMESTAMP
        )
      ).first

      if link
        # Update usage count
        DB[:magic_links].where(token: token).update(used_count: Sequel.expr(:used_count) + 1)

        # Store token in session for password setup
        session[:magic_link_token] = token
        session[:magic_link_id] = link[:id]
        redirect '/password-setup'
      else
        @error = "Invalid or expired magic link"
        erb :error
      end
    else
      redirect '/login'
    end
  else
    # First user setup
    erb :admin_setup
  end
end

# Admin setup submission
post '/setup' do
  unless is_admin_setup_complete?
    username = params[:username]&.strip
    password = params[:password]&.strip

    if username && !username.empty? && password && !password.empty?
      # Mark admin setup as complete
      DB[:admins].insert_conflict(:replace).insert(id: 1, is_setup_complete: true)

      # Create admin user
      create_user(username, password, true)

      # Create built-in AI user
      unless DB[:users].where(username: 'AI', is_ai: true).first
        ai_password = SecureRandom.urlsafe_base64(32)
        DB[:users].insert(
          username: 'AI',
          password_digest: BCrypt::Password.create(ai_password),
          is_admin: false,
          is_ai: true
        )
      end

      redirect '/'
    else
      @error = "Username and password are required"
      erb :admin_setup
    end
  else
    redirect '/setup'
  end
end

# Password setup for new users (via magic link)
get '/password-setup' do
  redirect '/login' unless session[:magic_link_token]
  erb :password_setup
end

post '/password-setup' do
  redirect '/login' unless session[:magic_link_token]

  username = params[:username]&.strip
  password = params[:password]&.strip
  password_confirmation = params[:password_confirmation]&.strip

  if username && !username.empty? && password && !password.empty?
    if password == password_confirmation
      # Check if username already exists
      existing_user = DB[:users].where(username: username).first
      if existing_user
        @error = "Username already taken"
        erb :password_setup
      else
        # Create new user
        magic_link_id = session[:magic_link_id]
        create_user(username, password, false, magic_link_id)

        # Clear magic link session data
        session.delete(:magic_link_token)
        session.delete(:magic_link_id)

        redirect '/'
      end
    else
      @error = "Passwords do not match"
      erb :password_setup
    end
  else
    @error = "Username and password are required"
    erb :password_setup
  end
end

# Room creation
get '/rooms/new' do
  user = current_user
  redirect '/login' unless user

  @current_user = user
  @users = DB[:users].all

  erb :new_room
end

post '/rooms' do
  user = current_user
  redirect '/login' unless user

  name = params[:name]&.strip
  description = params[:description]&.strip
  game_master_id = params[:game_master_id]&.to_i

  if name && !name.empty?
    # Create room
    room_id = DB[:rooms].insert(
      name: name,
      description: description,
      created_by: user[:id],
      game_master_id: game_master_id
    )

    # Add creator to room
    DB[:user_rooms].insert(
      user_id: user[:id],
      room_id: room_id
    )

    redirect "/rooms/#{room_id}"
  else
    @error = "Room name is required"
    @current_user = user
    @users = DB[:users].all
    erb :new_room
  end
end

# Individual room chat
get '/rooms/:id' do
  user = current_user
  redirect '/login' unless user

  room_id = params[:id].to_i

  # Check if user has access to this room
  access = DB[:user_rooms].where(user_id: user[:id], room_id: room_id).first
  unless access
    @error = "You don't have access to this room"
    erb :error
  else
    @room = DB[:rooms].where(id: room_id).first
    @username = user[:username]
    @is_admin = user[:is_admin]
    @room_id = room_id

    # Check if user can manage players (is GM or is creator when GM is AI)
    game_master = DB[:users].where(id: @room[:game_master_id]).first
    @can_manage_players = (user[:id] == @room[:game_master_id]) ||
                          (user[:id] == @room[:created_by] && game_master && game_master[:is_ai])

    # Get current players in the room
    @room_players = DB[:users]
      .join(:user_rooms, user_id: :id)
      .where(room_id: room_id)
      .select(Sequel[:users][:id], Sequel[:users][:username], Sequel[:users][:is_ai])
      .all

    # Get users not in the room
    player_ids = @room_players.map { |p| p[:id] }
    @available_users = DB[:users]
      .exclude(id: player_ids)
      .select(:id, :username, :is_ai)
      .all

    # Get chat history with rendered HTML
    messages_data = DB[:chat_messages]
      .join(:users, id: :user_id)
      .where(room_id: room_id)
      .order(Sequel[:chat_messages][:created_at])
      .select(
        Sequel[:chat_messages][:message],
        Sequel[:users][:username],
        Sequel[:users][:is_admin],
        Sequel[:chat_messages][:user_id]
      )
      .all

    @chat_history = messages_data.map do |msg|
      {
        html: render_message(msg[:user_id], msg[:username], msg[:message], room_id, is_own: msg[:user_id] == user[:id])
      }
    end

    erb :room
  end
end

# Add player to room
post '/rooms/:id/add-player' do
  user = current_user
  redirect '/login' unless user

  room_id = params[:id].to_i
  player_id = params[:player_id]&.to_i

  # Verify user has access to this room
  access = DB[:user_rooms].where(user_id: user[:id], room_id: room_id).first
  halt 403, "Access denied" unless access

  room = DB[:rooms].where(id: room_id).first
  halt 404, "Room not found" unless room

  # Check if user can manage players (is GM or is creator when GM is AI)
  game_master = DB[:users].where(id: room[:game_master_id]).first
  can_manage = (user[:id] == room[:game_master_id]) ||
               (user[:id] == room[:created_by] && game_master && game_master[:is_ai])

  halt 403, "Not authorized" unless can_manage

  # Add player to room if not already in it
  existing = DB[:user_rooms].where(user_id: player_id, room_id: room_id).first
  unless existing
    DB[:user_rooms].insert(
      user_id: player_id,
      room_id: room_id
    )
  end

  redirect "/rooms/#{room_id}"
end

# Render message HTML for current user
post '/rooms/:id/render-message' do
  user = current_user
  halt 401 unless user

  room_id = params[:id].to_i
  content_type :json

  request.body.rewind
  data = JSON.parse(request.body.read)
  message = data['message']

  html = render_message(user[:id], user[:username], message, room_id, is_own: true)

  { html: html }.to_json
end

# Login for returning users
get '/login' do
  redirect '/setup' unless is_admin_setup_complete?
  redirect '/' if current_user
  erb :login
end

post '/login' do
  username = params[:username]&.strip
  password = params[:password]&.strip

  if username && password
    user = authenticate_user(username, password)
    if user
      session[:user_id] = user[:id]
      redirect '/'
    else
      @error = "Invalid username or password"
      erb :login
    end
  else
    @error = "Username and password are required"
    erb :login
  end
end

# Admin panel
get '/admin' do
  user = current_user
  redirect '/setup' unless user && user[:is_admin]

  @magic_links = DB[:magic_links].where(is_active: true).order(Sequel.desc(:created_at)).all

  erb :admin
end

# Create magic link
post '/admin/create-link' do
  user = current_user
  redirect '/setup' unless user && user[:is_admin]

  expires_hours = params[:expires_hours]&.to_i
  token = SecureRandom.urlsafe_base64(32)

  link_data = { token: token }
  if expires_hours && expires_hours > 0
    expires_at = Time.now + (expires_hours * 3600)
    link_data[:expires_at] = expires_at
  end

  DB[:magic_links].insert(link_data)
  redirect '/admin'
end

# Deactivate magic link
post '/admin/deactivate-link/:id' do
  user = current_user
  redirect '/setup' unless user && user[:is_admin]

  DB[:magic_links].where(id: params[:id]).update(is_active: false)
  redirect '/admin'
end

# Logout
post '/logout' do
  session.clear
  redirect '/login'
end

# WebSocket endpoint
get '/ws' do
  user = current_user
  halt 401, "Authentication required" unless user && user[:username]

  # Get room_id from query string
  room_id = params[:room_id]&.to_i
  halt 400, "Room ID required" unless room_id

  # Verify user has access to this room
  access = DB[:user_rooms].where(user_id: user[:id], room_id: room_id).first
  halt 403, "Access denied" unless access

  if Faye::WebSocket.websocket?(request.env)
    ws = Faye::WebSocket.new(request.env)

    ws.on :open do |event|
      # Initialize room array if it doesn't exist
      settings.sockets[room_id] ||= []
      settings.sockets[room_id] << ws
      puts "Client connected: #{user[:username]} to room #{room_id}. Room total: #{settings.sockets[room_id].length}"
    end

    ws.on :message do |event|
      message = JSON.parse(event.data)

      # Save message to database
      DB[:chat_messages].insert(
        room_id: room_id,
        user_id: user[:id],
        message: message['message']
      )

      # Render message HTML
      message_html = render_message(user[:id], user[:username], message['message'], room_id, is_own: false)

      # Prepare broadcast message
      broadcast_data = {
        html: message_html,
        user_id: user[:id]
      }

      # Broadcast message only to clients in the same room
      if settings.sockets[room_id]
        settings.sockets[room_id].each do |socket|
          if socket != ws
            socket.send(JSON.generate(broadcast_data))
          end
        end
      end
    end

    ws.on :close do |event|
      if settings.sockets[room_id]
        settings.sockets[room_id].delete(ws)
        puts "Client disconnected: #{user[:username]} from room #{room_id}. Room total: #{settings.sockets[room_id].length}"
        # Clean up empty room arrays
        settings.sockets.delete(room_id) if settings.sockets[room_id].empty?
      end
    end

    # Return async Rack response
    ws.rack_response
  else
    status 400
    "WebSocket connection required"
  end
end
