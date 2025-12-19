require 'sinatra'
require 'faye/websocket'
require 'json'
require 'sequel'
require 'securerandom'
require 'bcrypt'
require 'securerandom'
require 'cgi'

set :sockets, {}  # Changed to hash to namespace by room_id
set :sockets_mutex, Mutex.new
set :ai_game_masters, {}  # Track AI Game Master instances by room_id
set :ai_gm_mutex, Mutex.new
set :world_builder_ais, {}  # Track WorldBuilderAI instances by world_id
set :world_builder_mutex, Mutex.new
set :session_secret, ENV.fetch('SESSION_SECRET') { SecureRandom.hex(64) }
enable :sessions

require_relative 'initializers/db.rb'
require_relative 'initializers/dice_roll.rb'
require_relative 'lib/models.rb'
require_relative 'lib/game_engine.rb'
# require_relative 'lib/ai_game_master.rb'  # Commented out - file removed
require_relative 'lib/world_builder_ai.rb'

# WebSocket ping thread - keeps connections alive
Thread.new do
  loop do
    sleep 5
    settings.sockets_mutex.synchronize do
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
end

# Helper methods
def current_user
  return nil unless session[:user_id]

  DB[:users].where(id: session[:user_id]).first
end

# Helper to broadcast DOM updates to WorldBuilder WebSocket clients
def broadcast_dom_update_to_world(world_id, message)
  settings.sockets_mutex.synchronize do
    sockets = settings.sockets["builder_#{world_id}"]
    if sockets
      sockets.each do |socket|
        begin
          socket.send(JSON.generate(message))
        rescue => e
          puts "[WorldBuilder] Broadcast error: #{e.message}"
        end
      end
    end
  end
end

# Helper to render ERB partials for WorldBuilder
def render_partial_for_world(template, locals)
  template_path = File.join(File.dirname(__FILE__), 'views', 'worlds', 'partials', "#{template}.erb")
  erb_content = File.read(template_path)
  erb = ERB.new(erb_content)

  # Create binding with locals
  binding_obj = binding
  locals.each do |key, value|
    binding_obj.local_variable_set(key, value)
  end

  erb.result(binding_obj)
end

# Helper to calculate location hierarchy level
def calculate_location_level(location, all_locations)
  level = 0
  current = location

  while current && current.parent_location_id
    level += 1
    current = all_locations.find { |l| l.id == current.parent_location_id }
    break if level > 10  # Safety check for circular references
  end

  level
end

def render_message(user_id, username, message, room_id, is_own: false, data: nil)
  room = DB[:rooms].where(id: room_id).first
  user = DB[:users].where(id: user_id).first

  # Parse data if it's a JSON string, handle empty or nil data
  parsed_data = nil
  if data && data != "{}"
    parsed_data = data.is_a?(String) ? JSON.parse(data) : data
  end

  # Check if this is a dice roll message
  if parsed_data && parsed_data['type'] == 'dice_roll'
    return erb :'messages/_dice_roll_message', locals: {
      username: username,
      dice_data: parsed_data,
      user_id: user_id
    }, layout: false
  end

  # Determine if this is a GM message
  is_gm = user_id == room[:game_master_id]

  template = is_gm ? :'messages/_gm_message' : :'messages/_player_message'

  erb template, locals: { username: username, message: message, is_own: is_own, user_id: user_id }, layout: false
end

def link_button(href, text)
  erb :'buttons/_link_button', locals: { href: href, text: text }, layout: false
end

def submit_button(text)
  erb :'buttons/_submit_button', locals: { text: text }, layout: false
end

def ascii_dice(dice_type, value)
  erb :"ascii/_d#{dice_type}.html", locals: { value: value }, layout: false
end

def require_auth
  redirect '/login' unless current_user
end

def is_admin_setup_complete?
  result = DB[:admins].first
  result && result[:is_setup_complete]
end

def game_engine
  @game_engine ||= GameEngine.new(DB)
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
  @world_templates = World.where(is_template: true).order(:name).all

  erb :new_room
end

post '/rooms' do
  user = current_user
  redirect '/login' unless user

  name = params[:name]&.strip
  description = params[:description]&.strip
  game_master_id = params[:game_master_id]&.to_i
  world_template_id = params[:world_template_id]&.strip

  if name && !name.empty?
    # Copy world template if selected
    world_id = nil
    if world_template_id && !world_template_id.empty?
      result = game_engine.copy_world(
        world_template_id.to_i,
        new_name: "#{name} World",
        created_by: user[:id],
        is_template: false
      )

      if result[:success]
        world_id = result[:world_id]
      else
        @error = "Failed to copy world template: #{result[:error]}"
        @current_user = user
        @users = DB[:users].all
        @world_templates = World.where(is_template: true).order(:name).all
        return erb :new_room
      end
    end

    # Create room
    room_id = DB[:rooms].insert(
      name: name,
      description: description,
      created_by: user[:id],
      game_master_id: game_master_id,
      world_id: world_id
    )

    # Add creator to room
    DB[:user_rooms].insert(
      user_id: user[:id],
      room_id: room_id
    )

    # Initialize AI Game Master if GM is AI
    ai_user = DB[:users].where(is_ai: true).first
    if ai_user && game_master_id == ai_user[:id] && defined?(AIGameMaster)
      settings.ai_gm_mutex.synchronize do
        settings.ai_game_masters[room_id] = AIGameMaster.new(
          room_id,
          name,
          description || "",
          DB,
          settings.sockets,
          settings.sockets_mutex
        )
      end
    end

    redirect "/rooms/#{room_id}"
  else
    @error = "Room name is required"
    @current_user = user
    @users = DB[:users].all
    @world_templates = World.where(is_template: true).order(:name).all
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

    # Get current players in the room with mute status and hand raised
    @room_players = DB[:users]
      .join(:user_rooms, user_id: :id)
      .where(room_id: room_id)
      .select(Sequel[:users][:id], Sequel[:users][:username], Sequel[:users][:is_ai], Sequel[:user_rooms][:is_muted], Sequel[:user_rooms][:hand_raised])
      .all

    # Get current user's mute and hand raised status
    @is_muted = access[:is_muted]
    @hand_raised = access[:hand_raised]

    # Restore AI Game Master if needed (after server restart)
    if game_master && game_master[:is_ai] && !settings.ai_game_masters[room_id] && defined?(AIGameMaster)
      settings.ai_gm_mutex.synchronize do
        unless settings.ai_game_masters[room_id]
          settings.ai_game_masters[room_id] = AIGameMaster.new(
            room_id,
            @room[:name],
            @room[:description] || "",
            DB,
            settings.sockets,
            settings.sockets_mutex,
            restore: true  # Flag to skip initial narration
          )
        end
      end
    end

    # Get users not in the room
    player_ids = @room_players.map { |p| p[:id] }
    @available_users = DB[:users]
      .exclude(id: player_ids)
      .select(:id, :username, :is_ai)
      .all

    # Get total message count
    @total_messages = DB[:chat_messages].where(room_id: room_id).count

    # Get last 15 messages for chat history
    @chat_history = DB[:chat_messages]
      .join(:users, id: :user_id)
      .where(room_id: room_id)
      .order(Sequel[:chat_messages][:created_at])
      .reverse
      .limit(15)
      .select(
        Sequel[:chat_messages][:message],
        Sequel[:chat_messages][:data],
        Sequel[:users][:username],
        Sequel[:users][:is_admin],
        Sequel[:chat_messages][:user_id]
      )
      .all
      .reverse

    erb :room
  end
end

# Fetch older messages for infinite scroll
get '/rooms/:id/messages' do
  user = current_user
  halt 401 unless user

  room_id = params[:id].to_i
  offset = params[:offset]&.to_i || 0

  # Verify access
  access = DB[:user_rooms].where(user_id: user[:id], room_id: room_id).first
  halt 403 unless access

  content_type :json

  # Get 15 older messages
  messages = DB[:chat_messages]
    .join(:users, id: :user_id)
    .where(room_id: room_id)
    .order(Sequel[:chat_messages][:created_at])
    .reverse
    .limit(15)
    .offset(offset)
    .select(
      Sequel[:chat_messages][:message],
      Sequel[:chat_messages][:data],
      Sequel[:users][:username],
      Sequel[:users][:is_admin],
      Sequel[:chat_messages][:user_id]
    )
    .all
    .reverse

  # Render messages to HTML
  html_messages = messages.map do |msg|
    render_message(msg[:user_id], msg[:username], msg[:message], room_id, is_own: msg[:user_id] == user[:id], data: msg[:data])
  end

  { messages: html_messages }.to_json
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

    # Notify AI Game Master if applicable
    ai_gm = settings.ai_game_masters[room_id]
    if ai_gm
      player = DB[:users].where(id: player_id).first
      Thread.new { ai_gm.handle_player_joined(player[:username]) }
    end
  end

  redirect "/rooms/#{room_id}"
end

# Toggle mute status for a player in a room
post '/rooms/:id/toggle-mute' do
  user = current_user
  halt 401 unless user

  room_id = params[:id].to_i

  # Parse JSON body
  request.body.rewind
  data = JSON.parse(request.body.read)
  player_id = data['player_id']&.to_i

  content_type :json

  # Verify user has access to this room
  access = DB[:user_rooms].where(user_id: user[:id], room_id: room_id).first
  halt 403, { error: "Access denied" }.to_json unless access

  room = DB[:rooms].where(id: room_id).first
  halt 404, { error: "Room not found" }.to_json unless room

  # Check if user can manage players (is GM or is creator when GM is AI)
  game_master = DB[:users].where(id: room[:game_master_id]).first
  can_manage = (user[:id] == room[:game_master_id]) ||
               (user[:id] == room[:created_by] && game_master && game_master[:is_ai])

  halt 403, { error: "Not authorized" }.to_json unless can_manage

  # Prevent GM from muting themselves
  if player_id == room[:game_master_id]
    halt 403, { error: "Cannot mute the Game Master" }.to_json
  end

  # Get the user_room record
  user_room = DB[:user_rooms].where(user_id: player_id, room_id: room_id).first
  halt 404, { error: "Player not in room" }.to_json unless user_room

  # Toggle mute status
  new_mute_status = !user_room[:is_muted]
  DB[:user_rooms].where(user_id: player_id, room_id: room_id).update(is_muted: new_mute_status)

  # Get player username
  player = DB[:users].where(id: player_id).first

  # Broadcast mute status change to all users in the room
  broadcast_data = {
    type: 'mute_status',
    user_id: player_id,
    is_muted: new_mute_status,
    username: player[:username]
  }

  settings.sockets_mutex.synchronize do
    if settings.sockets[room_id]
      settings.sockets[room_id].each do |socket|
        socket.send(JSON.generate(broadcast_data))
      end
    end
  end

  { success: true, is_muted: new_mute_status }.to_json
end

# Raise hand
post '/rooms/:id/raise-hand' do
  user = current_user
  halt 401 unless user

  room_id = params[:id].to_i
  content_type :json

  # Verify user has access to this room
  access = DB[:user_rooms].where(user_id: user[:id], room_id: room_id).first
  halt 403, { error: "Access denied" }.to_json unless access

  # Set hand_raised to true
  DB[:user_rooms].where(user_id: user[:id], room_id: room_id).update(hand_raised: true)

  # Broadcast hand raised status
  broadcast_data = {
    type: 'hand_raised',
    user_id: user[:id],
    username: user[:username],
    raised: true
  }

  settings.sockets_mutex.synchronize do
    if settings.sockets[room_id]
      settings.sockets[room_id].each do |socket|
        socket.send(JSON.generate(broadcast_data))
      end
    end
  end

  # Notify AI Game Master if applicable
  ai_gm = settings.ai_game_masters[room_id]
  if ai_gm
    Thread.new { ai_gm.handle_hand_raised(user[:username]) }
  end

  { success: true, hand_raised: true }.to_json
end

# Lower hand
post '/rooms/:id/lower-hand' do
  user = current_user
  halt 401 unless user

  room_id = params[:id].to_i
  content_type :json

  # Verify user has access to this room
  access = DB[:user_rooms].where(user_id: user[:id], room_id: room_id).first
  halt 403, { error: "Access denied" }.to_json unless access

  # Set hand_raised to false
  DB[:user_rooms].where(user_id: user[:id], room_id: room_id).update(hand_raised: false)

  # Broadcast hand lowered status
  broadcast_data = {
    type: 'hand_raised',
    user_id: user[:id],
    username: user[:username],
    raised: false
  }

  settings.sockets_mutex.synchronize do
    if settings.sockets[room_id]
      settings.sockets[room_id].each do |socket|
        socket.send(JSON.generate(broadcast_data))
      end
    end
  end

  { success: true, hand_raised: false }.to_json
end

# Render message HTML for current user
post '/rooms/:id/render-message' do
  user = current_user
  halt 401 unless user

  room_id = params[:id].to_i
  content_type :json

  request.body.rewind
  data = JSON.parse(request.body.read)
  message_text = data['message']
  data_json = '{}'

  # Check if this is a dice roll command
  if message_text =~ /^\/roll\s+(.+)/
    dice_command = $1

    begin
      # Use DiceRoll class to roll the dice
      dice_roll = DiceRoll.new(dice_command)

      # Prepare data to store
      dice_data = {
        type: 'dice_roll',
        command: dice_command,
        result_dice: dice_roll.result_dice,
        modifiers: dice_roll.modifiers,
        dice_total: dice_roll.result_dice.sum(&:first),
        total: dice_roll.total
      }

      data_json = JSON.generate(dice_data)
      message_text = '' # Clear the message text for dice rolls
    rescue => e
      puts "Dice roll error: #{e.message}"
      # If there's an error, treat it as a normal message
    end
  end

  html = render_message(user[:id], user[:username], message_text, room_id, is_own: true, data: data_json)

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

# World Builder - List templates
get '/worlds/builder' do
  user = current_user
  redirect '/login' unless user

  @worlds = World.where(is_template: true).order(Sequel.desc(:created_at)).all
  erb :'worlds/builder_index'
end

# World Builder - New template
get '/worlds/builder/new' do
  user = current_user
  redirect '/login' unless user

  erb :'worlds/builder_new'
end

# World Builder - Create template
post '/worlds/builder' do
  user = current_user
  redirect '/login' unless user

  name = params[:name]&.strip
  description = params[:description]&.strip

  if name && !name.empty?
    result = game_engine.create_world(
      name: name,
      description: description,
      created_by: user[:id],
      is_template: true
    )

    if result[:success]
      redirect "/worlds/builder/#{result[:world_id]}"
    else
      @error = result[:error]
      erb :'worlds/builder_new'
    end
  else
    @error = "World name is required"
    erb :'worlds/builder_new'
  end
end

# World Builder - Edit template
get '/worlds/builder/:id' do
  user = current_user
  redirect '/login' unless user

  world_id = params[:id].to_i
  @world = World[world_id]

  halt 404, "World not found" unless @world
  halt 403, "Not authorized" unless @world.is_template

  # Get all locations, characters, items, containers, quests for this world
  @locations = Location.where(world_id: world_id).order(:name).all
  @characters = Character.where(world_id: world_id).order(:name).all
  @items = Item.where(world_id: world_id, character_id: nil, container_id: nil).order(:name).all
  @containers = Container.where(world_id: world_id).order(:name).all
  @connections = Connection.where(world_id: world_id).all
  @quests = Quest.where(world_id: world_id).order(:name).all

  # Get undo/redo history from session
  session[:world_actions] ||= {}
  session[:world_actions][world_id.to_s] ||= { undo_stack: [], redo_stack: [] }
  @undo_available = session[:world_actions][world_id.to_s][:undo_stack].any?
  @redo_available = session[:world_actions][world_id.to_s][:redo_stack].any?

  # Initialize WorldBuilderAI if not already exists
  settings.world_builder_mutex.synchronize do
    unless settings.world_builder_ais[world_id]
      settings.world_builder_ais[world_id] = WorldBuilderAI.new(
        world_id,
        DB,
        settings.sockets,
        settings.sockets_mutex,
        restore: true
      )
    end
  end

  erb :'worlds/builder_edit'
end

# World Builder - Perform action
post '/worlds/builder/:id/action' do
  user = current_user
  halt 401 unless user

  world_id = params[:id].to_i
  world = World[world_id]

  halt 404 unless world
  halt 403 unless world.is_template

  content_type :json

  request.body.rewind
  data = JSON.parse(request.body.read)

  action_type = data['action_type']
  action_params = data['params'] || {}

  # Initialize action history
  session[:world_actions] ||= {}
  session[:world_actions][world_id.to_s] ||= { undo_stack: [], redo_stack: [] }

  result = nil
  inverse_action = nil

  begin
    case action_type
    when 'create_location'
      result = game_engine.create_location(
        world_id: world_id,
        name: action_params['name'],
        description: action_params['description'],
        location_type: action_params['location_type'],
        parent_location_id: action_params['parent_location_id']&.to_i
      )
      if result[:success]
        inverse_action = {
          action_type: 'delete_location',
          params: { location_id: result[:location_id] }
        }
      end

    when 'create_connection'
      required_item_id = action_params['required_item_id']
      required_item_id = nil if required_item_id.to_s.empty?

      result = game_engine.create_connection(
        world_id,
        action_params['from_location_id'].to_i,
        action_params['to_location_id'].to_i,
        {
          direction: action_params['direction'],
          description: action_params['description'],
          connection_type: action_params['connection_type'] || 'passage',
          is_visible: action_params['is_visible'] != 'false',
          is_locked: action_params['is_locked'] == 'true',
          is_open: action_params['is_open'] != 'false',
          required_item_id: required_item_id&.to_i,
          is_bidirectional: action_params['is_bidirectional'] == 'true',
          reverse_description: action_params['reverse_description']
        }
      )
      if result[:success]
        inverse_action = {
          action_type: 'delete_connection',
          params: { connection_id: result[:connection_id] }
        }
      end

    when 'create_character'
      result = game_engine.create_npc(
        world_id: world_id,
        location_id: action_params['location_id']&.to_i,
        name: action_params['name'],
        description: action_params['description'],
        max_hp: action_params['max_hp']&.to_i || 10,
        strength: action_params['strength']&.to_i || 10,
        intelligence: action_params['intelligence']&.to_i || 10,
        charisma: action_params['charisma']&.to_i || 10,
        is_hostile: action_params['is_hostile'] == 'true',
        gold: action_params['gold']&.to_i || 0
      )
      if result[:success]
        inverse_action = {
          action_type: 'delete_character',
          params: { character_id: result[:character_id] }
        }
      end

    when 'create_item'
      result = game_engine.create_item(
        world_id: world_id,
        location_id: action_params['location_id']&.to_i,
        name: action_params['name'],
        description: action_params['description'],
        item_type: action_params['item_type'] || 'misc',
        cost: action_params['cost']&.to_i || 0
      )
      if result[:success]
        inverse_action = {
          action_type: 'delete_item',
          params: { item_id: result[:item_id] }
        }
      end

    when 'create_container'
      result = game_engine.create_container(
        world_id: world_id,
        location_id: action_params['location_id']&.to_i,
        name: action_params['name'],
        description: action_params['description'],
        is_locked: action_params['is_locked'] == 'true'
      )
      if result[:success]
        inverse_action = {
          action_type: 'delete_container',
          params: { container_id: result[:container_id] }
        }
      end

    when 'create_quest'
      result = game_engine.create_quest(
        world_id,
        nil,  # Builder quests don't have a room_id
        {
          name: action_params['name'],
          description: action_params['description'],
          quest_type: action_params['quest_type'] || 'main',
          status: action_params['status'] || 'active'
        }
      )
      if result[:success]
        # Create objectives if provided
        if action_params['objectives']
          action_params['objectives'].each do |obj_data|
            QuestObjective.create(
              quest_id: result[:quest_id],
              description: obj_data['description'],
              is_completed: obj_data['is_completed'] || false,
              display_order: 0
            )
          end
        end

        inverse_action = {
          action_type: 'delete_quest',
          params: { quest_id: result[:quest_id] }
        }
      end

    # Delete actions (for undo)
    when 'delete_location'
      location = Location[action_params['location_id'].to_i]
      if location
        location_id = location.id
        inverse_action = {
          action_type: 'restore_location',
          params: {
            location_id: location.id,
            world_id: location.world_id,
            name: location.name,
            description: location.description,
            location_type: location.location_type
          }
        }
        location.delete

        # Broadcast DOM update via WebSocket
        broadcast_dom_update_to_world(world_id, {
          type: 'dom_update',
          action: 'remove',
          target: "[data-location-id='#{location_id}']",
          html: nil,
          entity_type: 'location',
          entity_id: location_id
        })

        # Update stats
        stats_count = Location.where(world_id: world_id).count
        broadcast_dom_update_to_world(world_id, {
          type: 'dom_update',
          action: 'update_stats',
          target: '#stats-locations',
          html: stats_count.to_s,
          entity_type: 'location',
          entity_id: nil
        })

        result = { success: true }
      end

    when 'delete_connection'
      connection = Connection[action_params['connection_id'].to_i]
      if connection
        connection_id = connection.id
        inverse_action = {
          action_type: 'restore_connection',
          params: {
            connection_id: connection.id,
            world_id: connection.world_id,
            from_location_id: connection.from_location_id,
            to_location_id: connection.to_location_id,
            direction: connection.direction,
            description: connection.description,
            is_bidirectional: connection.is_bidirectional
          }
        }
        connection.delete

        # Broadcast DOM update via WebSocket
        broadcast_dom_update_to_world(world_id, {
          type: 'dom_update',
          action: 'remove',
          target: "[data-connection-id='#{connection_id}']",
          html: nil,
          entity_type: 'connection',
          entity_id: connection_id
        })

        # Update stats
        stats_count = Connection.where(world_id: world_id).count
        broadcast_dom_update_to_world(world_id, {
          type: 'dom_update',
          action: 'update_stats',
          target: '#stats-connections',
          html: stats_count.to_s,
          entity_type: 'connection',
          entity_id: nil
        })

        result = { success: true }
      end

    when 'delete_character'
      character = Character[action_params['character_id'].to_i]
      if character
        character_id = character.id
        inverse_action = {
          action_type: 'restore_character',
          params: {
            character_id: character.id,
            world_id: character.world_id,
            location_id: character.location_id,
            name: character.name,
            description: character.description,
            max_hp: character.max_hp,
            strength: character.strength,
            intelligence: character.intelligence,
            charisma: character.charisma,
            is_hostile: character.is_hostile
          }
        }
        character.delete

        # Broadcast DOM update via WebSocket
        broadcast_dom_update_to_world(world_id, {
          type: 'dom_update',
          action: 'remove',
          target: "[data-character-id='#{character_id}']",
          html: nil,
          entity_type: 'character',
          entity_id: character_id
        })

        # Update stats
        stats_count = Character.where(world_id: world_id).count
        broadcast_dom_update_to_world(world_id, {
          type: 'dom_update',
          action: 'update_stats',
          target: '#stats-characters',
          html: stats_count.to_s,
          entity_type: 'character',
          entity_id: nil
        })

        result = { success: true }
      end

    when 'delete_item'
      item = Item[action_params['item_id'].to_i]
      if item
        item_id = item.id
        inverse_action = {
          action_type: 'restore_item',
          params: {
            item_id: item.id,
            world_id: item.world_id,
            location_id: item.location_id,
            name: item.name,
            description: item.description,
            item_type: item.item_type,
            cost: item.cost
          }
        }
        item.delete

        # Broadcast DOM update via WebSocket
        broadcast_dom_update_to_world(world_id, {
          type: 'dom_update',
          action: 'remove',
          target: "[data-item-id='#{item_id}']",
          html: nil,
          entity_type: 'item',
          entity_id: item_id
        })

        # Update stats
        stats_count = Item.where(world_id: world_id, character_id: nil, container_id: nil).count
        broadcast_dom_update_to_world(world_id, {
          type: 'dom_update',
          action: 'update_stats',
          target: '#stats-items',
          html: stats_count.to_s,
          entity_type: 'item',
          entity_id: nil
        })

        result = { success: true }
      end

    when 'delete_container'
      container = Container[action_params['container_id'].to_i]
      if container
        container_id = container.id
        inverse_action = {
          action_type: 'restore_container',
          params: {
            container_id: container.id,
            world_id: container.world_id,
            location_id: container.location_id,
            name: container.name,
            description: container.description,
            is_locked: container.is_locked
          }
        }
        container.delete

        # Broadcast DOM update via WebSocket
        broadcast_dom_update_to_world(world_id, {
          type: 'dom_update',
          action: 'remove',
          target: "[data-container-id='#{container_id}']",
          html: nil,
          entity_type: 'container',
          entity_id: container_id
        })

        # Update stats
        stats_count = Container.where(world_id: world_id).count
        broadcast_dom_update_to_world(world_id, {
          type: 'dom_update',
          action: 'update_stats',
          target: '#stats-containers',
          html: stats_count.to_s,
          entity_type: 'container',
          entity_id: nil
        })

        result = { success: true }
      end

    when 'delete_quest'
      quest = Quest[action_params['quest_id'].to_i]
      if quest
        quest_id = quest.id
        # Save objectives for restoration
        objectives_data = quest.quest_objectives.map do |obj|
          {
            description: obj.description,
            is_completed: obj.is_completed,
            display_order: obj.display_order
          }
        end

        inverse_action = {
          action_type: 'restore_quest',
          params: {
            quest_id: quest.id,
            world_id: quest.world_id,
            room_id: quest.room_id,
            name: quest.name,
            description: quest.description,
            quest_type: quest.quest_type,
            status: quest.status,
            objectives: objectives_data
          }
        }
        quest.delete

        # Broadcast DOM update via WebSocket
        broadcast_dom_update_to_world(world_id, {
          type: 'dom_update',
          action: 'remove',
          target: "[data-quest-id='#{quest_id}']",
          html: nil,
          entity_type: 'quest',
          entity_id: quest_id
        })

        # Update stats
        stats_count = Quest.where(world_id: world_id).count
        broadcast_dom_update_to_world(world_id, {
          type: 'dom_update',
          action: 'update_stats',
          target: '#stats-quests',
          html: stats_count.to_s,
          entity_type: 'quest',
          entity_id: nil
        })

        result = { success: true }
      end

    # Restore actions (for redo)
    when 'restore_location'
      Location.create(action_params.transform_keys(&:to_sym))
      result = { success: true }

    when 'restore_connection'
      Connection.create(action_params.transform_keys(&:to_sym))
      result = { success: true }

    when 'restore_character'
      Character.create(action_params.transform_keys(&:to_sym).merge(character_type: 'npc'))
      result = { success: true }

    when 'restore_item'
      Item.create(action_params.transform_keys(&:to_sym))
      result = { success: true }

    when 'restore_container'
      Container.create(action_params.transform_keys(&:to_sym))
      result = { success: true }

    when 'restore_quest'
      quest = Quest.create(
        id: action_params['quest_id'],
        world_id: action_params['world_id'],
        room_id: action_params['room_id'],
        name: action_params['name'],
        description: action_params['description'],
        quest_type: action_params['quest_type'],
        status: action_params['status']
      )
      # Restore objectives
      if action_params['objectives']
        action_params['objectives'].each do |obj_data|
          QuestObjective.create(
            quest_id: quest.id,
            description: obj_data['description'],
            is_completed: obj_data['is_completed'],
            display_order: obj_data['display_order']
          )
        end
      end
      result = { success: true }

    else
      halt 400, { error: "Unknown action type: #{action_type}" }.to_json
    end

    # If action succeeded and we have an inverse, add to undo stack
    if result && result[:success] && inverse_action
      session[:world_actions][world_id.to_s][:undo_stack] << inverse_action
      session[:world_actions][world_id.to_s][:redo_stack].clear # Clear redo on new action
    end

    result.to_json
  rescue => e
    puts "World builder error: #{e.message}"
    puts e.backtrace.join("\n")
    { error: e.message }.to_json
  end
end

# World Builder - Get entity for editing
get '/worlds/builder/:world_id/locations/:id/edit' do
  user = current_user
  halt 401 unless user

  world_id = params[:world_id].to_i
  world = World[world_id]
  halt 404 unless world
  halt 403 unless world.is_template

  content_type :json
  location = Location[params[:id].to_i]
  halt 404 unless location
  halt 403 unless location.world_id == world_id

  location.values.to_json
end

get '/worlds/builder/:world_id/connections/:id/edit' do
  user = current_user
  halt 401 unless user

  world_id = params[:world_id].to_i
  world = World[world_id]
  halt 404 unless world
  halt 403 unless world.is_template

  content_type :json
  connection = Connection[params[:id].to_i]
  halt 404 unless connection
  halt 403 unless connection.world_id == world_id

  connection.values.to_json
end

get '/worlds/builder/:world_id/characters/:id/edit' do
  user = current_user
  halt 401 unless user

  world_id = params[:world_id].to_i
  world = World[world_id]
  halt 404 unless world
  halt 403 unless world.is_template

  content_type :json
  character = Character[params[:id].to_i]
  halt 404 unless character
  halt 403 unless character.world_id == world_id

  character.values.to_json
end

get '/worlds/builder/:world_id/items/:id/edit' do
  user = current_user
  halt 401 unless user

  world_id = params[:world_id].to_i
  world = World[world_id]
  halt 404 unless world
  halt 403 unless world.is_template

  content_type :json
  item = Item[params[:id].to_i]
  halt 404 unless item
  halt 403 unless item.world_id == world_id

  item.values.to_json
end

get '/worlds/builder/:world_id/containers/:id/edit' do
  user = current_user
  halt 401 unless user

  world_id = params[:world_id].to_i
  world = World[world_id]
  halt 404 unless world
  halt 403 unless world.is_template

  content_type :json
  container = Container[params[:id].to_i]
  halt 404 unless container
  halt 403 unless container.world_id == world_id

  container.values.to_json
end

get '/worlds/builder/:world_id/quests/:id/edit' do
  user = current_user
  halt 401 unless user

  world_id = params[:world_id].to_i
  world = World[world_id]
  halt 404 unless world
  halt 403 unless world.is_template

  content_type :json
  quest = Quest[params[:id].to_i]
  halt 404 unless quest
  halt 403 unless quest.world_id == world_id

  # Include objectives in the response
  quest_data = quest.values
  quest_data[:objectives] = quest.quest_objectives.map(&:values)
  quest_data.to_json
end

# World Builder - Update entity
put '/worlds/builder/:world_id/locations/:id' do
  user = current_user
  halt 401 unless user

  world_id = params[:world_id].to_i
  world = World[world_id]
  halt 404 unless world
  halt 403 unless world.is_template

  content_type :json

  request.body.rewind
  data = JSON.parse(request.body.read)

  location = Location[params[:id].to_i]
  halt 404 unless location
  halt 403 unless location.world_id == world_id

  begin
    location.update(
      name: data['name'],
      description: data['description'],
      location_type: data['location_type'],
      parent_location_id: data['parent_location_id']&.to_i
    )

    # Broadcast DOM update via WebSocket
    locations = Location.where(world_id: world_id).order(:name).all
    level = calculate_location_level(location, locations)
    html = render_partial_for_world('_location_card', { location: location, locations: locations, level: level })

    broadcast_dom_update_to_world(world_id, {
      type: 'dom_update',
      action: 'replace',
      target: "[data-location-id='#{location.id}']",
      html: html,
      entity_type: 'location',
      entity_id: location.id,
      entity_data: { id: location.id, name: location.name, location_type: location.location_type, parent_location_id: location.parent_location_id }
    })

    { success: true, location_id: location.id }.to_json
  rescue => e
    { error: e.message }.to_json
  end
end

put '/worlds/builder/:world_id/connections/:id' do
  user = current_user
  halt 401 unless user

  world_id = params[:world_id].to_i
  world = World[world_id]
  halt 404 unless world
  halt 403 unless world.is_template

  content_type :json

  request.body.rewind
  data = JSON.parse(request.body.read)

  connection = Connection[params[:id].to_i]
  halt 404 unless connection
  halt 403 unless connection.world_id == world_id

  begin
    required_item_id = data['required_item_id']
    required_item_id = nil if required_item_id.to_s.empty?

    connection.update(
      from_location_id: data['from_location_id']&.to_i,
      to_location_id: data['to_location_id']&.to_i,
      direction: data['direction'],
      description: data['description'],
      connection_type: data['connection_type'] || 'passage',
      is_visible: data['is_visible'] != 'false',
      is_locked: data['is_locked'] == 'true',
      is_open: data['is_open'] != 'false',
      required_item_id: required_item_id&.to_i,
      is_bidirectional: data['is_bidirectional'] == 'true',
      reverse_description: data['reverse_description']
    )

    # Broadcast DOM update via WebSocket
    locations = Location.where(world_id: world_id).order(:name).all
    html = render_partial_for_world('_connection_card', { connection: connection, locations: locations })

    broadcast_dom_update_to_world(world_id, {
      type: 'dom_update',
      action: 'replace',
      target: "[data-connection-id='#{connection.id}']",
      html: html,
      entity_type: 'connection',
      entity_id: connection.id,
      entity_data: { id: connection.id, from_location_id: connection.from_location_id, to_location_id: connection.to_location_id, is_bidirectional: connection.is_bidirectional }
    })

    { success: true, connection_id: connection.id }.to_json
  rescue => e
    { error: e.message }.to_json
  end
end

put '/worlds/builder/:world_id/characters/:id' do
  user = current_user
  halt 401 unless user

  world_id = params[:world_id].to_i
  world = World[world_id]
  halt 404 unless world
  halt 403 unless world.is_template

  content_type :json

  request.body.rewind
  data = JSON.parse(request.body.read)

  character = Character[params[:id].to_i]
  halt 404 unless character
  halt 403 unless character.world_id == world_id

  begin
    character.update(
      name: data['name'],
      description: data['description'],
      location_id: data['location_id']&.to_i,
      max_hp: data['max_hp']&.to_i || 10,
      strength: data['strength']&.to_i || 10,
      intelligence: data['intelligence']&.to_i || 10,
      charisma: data['charisma']&.to_i || 10,
      is_hostile: data['is_hostile'] == 'true',
      gold: data['gold']&.to_i || 0
    )

    # Broadcast DOM update via WebSocket
    locations = Location.where(world_id: world_id).order(:name).all
    html = render_partial_for_world('_character_card', { character: character, locations: locations })

    broadcast_dom_update_to_world(world_id, {
      type: 'dom_update',
      action: 'replace',
      target: "[data-character-id='#{character.id}']",
      html: html,
      entity_type: 'character',
      entity_id: character.id,
      entity_data: { id: character.id, name: character.name, location_id: character.location_id }
    })

    { success: true, character_id: character.id }.to_json
  rescue => e
    { error: e.message }.to_json
  end
end

put '/worlds/builder/:world_id/items/:id' do
  user = current_user
  halt 401 unless user

  world_id = params[:world_id].to_i
  world = World[world_id]
  halt 404 unless world
  halt 403 unless world.is_template

  content_type :json

  request.body.rewind
  data = JSON.parse(request.body.read)

  item = Item[params[:id].to_i]
  halt 404 unless item
  halt 403 unless item.world_id == world_id

  begin
    item.update(
      name: data['name'],
      description: data['description'],
      location_id: data['location_id']&.to_i,
      item_type: data['item_type'] || 'misc',
      cost: data['cost']&.to_i || 0
    )

    # Broadcast DOM update via WebSocket
    locations = Location.where(world_id: world_id).order(:name).all
    html = render_partial_for_world('_item_card', { item: item, locations: locations })

    broadcast_dom_update_to_world(world_id, {
      type: 'dom_update',
      action: 'replace',
      target: "[data-item-id='#{item.id}']",
      html: html,
      entity_type: 'item',
      entity_id: item.id,
      entity_data: { id: item.id, name: item.name, location_id: item.location_id }
    })

    { success: true, item_id: item.id }.to_json
  rescue => e
    { error: e.message }.to_json
  end
end

put '/worlds/builder/:world_id/containers/:id' do
  user = current_user
  halt 401 unless user

  world_id = params[:world_id].to_i
  world = World[world_id]
  halt 404 unless world
  halt 403 unless world.is_template

  content_type :json

  request.body.rewind
  data = JSON.parse(request.body.read)

  container = Container[params[:id].to_i]
  halt 404 unless container
  halt 403 unless container.world_id == world_id

  begin
    container.update(
      name: data['name'],
      description: data['description'],
      location_id: data['location_id']&.to_i,
      is_locked: data['is_locked'] == 'true'
    )

    # Broadcast DOM update via WebSocket
    locations = Location.where(world_id: world_id).order(:name).all
    html = render_partial_for_world('_container_card', { container: container, locations: locations })

    broadcast_dom_update_to_world(world_id, {
      type: 'dom_update',
      action: 'replace',
      target: "[data-container-id='#{container.id}']",
      html: html,
      entity_type: 'container',
      entity_id: container.id,
      entity_data: { id: container.id, name: container.name, location_id: container.location_id }
    })

    { success: true, container_id: container.id }.to_json
  rescue => e
    { error: e.message }.to_json
  end
end

put '/worlds/builder/:world_id/quests/:id' do
  user = current_user
  halt 401 unless user

  world_id = params[:world_id].to_i
  world = World[world_id]
  halt 404 unless world
  halt 403 unless world.is_template

  content_type :json

  request.body.rewind
  data = JSON.parse(request.body.read)

  quest = Quest[params[:id].to_i]
  halt 404 unless quest
  halt 403 unless quest.world_id == world_id

  begin
    # Update quest basic info
    quest.update(
      name: data['name'],
      description: data['description'],
      quest_type: data['quest_type'],
      status: data['status']
    )

    # Handle objectives if provided
    if data['objectives']
      objectives_data = data['objectives']
      existing_objective_ids = []

      objectives_data.each do |obj_data|
        if obj_data['id'] && !obj_data['id'].to_s.empty?
          # Update existing objective
          objective_id = obj_data['id'].to_i
          objective = QuestObjective[objective_id]
          if objective && objective.quest_id == quest.id
            objective.update(
              description: obj_data['description'],
              is_completed: obj_data['is_completed'] || false
            )
            existing_objective_ids << objective_id
          end
        else
          # Create new objective
          new_objective = QuestObjective.create(
            quest_id: quest.id,
            description: obj_data['description'],
            is_completed: obj_data['is_completed'] || false,
            display_order: 0
          )
          existing_objective_ids << new_objective.id
        end
      end

      # Delete objectives that were removed (not in the update)
      quest.quest_objectives.each do |objective|
        unless existing_objective_ids.include?(objective.id)
          objective.destroy
        end
      end
    end

    # Broadcast DOM update via WebSocket
    html = render_partial_for_world('_quest_card', { quest: quest })

    broadcast_dom_update_to_world(world_id, {
      type: 'dom_update',
      action: 'replace',
      target: "[data-quest-id='#{quest.id}']",
      html: html,
      entity_type: 'quest',
      entity_id: quest.id
    })

    { success: true, quest_id: quest.id }.to_json
  rescue => e
    { error: e.message }.to_json
  end
end

# World Builder - Undo
post '/worlds/builder/:id/undo' do
  user = current_user
  halt 401 unless user

  world_id = params[:id].to_i
  world = World[world_id]

  halt 404 unless world
  halt 403 unless world.is_template

  content_type :json

  session[:world_actions] ||= {}
  session[:world_actions][world_id.to_s] ||= { undo_stack: [], redo_stack: [] }

  undo_stack = session[:world_actions][world_id.to_s][:undo_stack]
  redo_stack = session[:world_actions][world_id.to_s][:redo_stack]

  if undo_stack.empty?
    halt 400, { error: "Nothing to undo" }.to_json
  end

  action = undo_stack.pop

  # Execute the inverse action
  request.body.rewind
  request.body.write({ action_type: action['action_type'], params: action['params'] }.to_json)
  request.body.rewind

  # Temporarily bypass undo stack update
  begin
    case action['action_type']
    when 'delete_location', 'delete_connection', 'delete_character', 'delete_item', 'delete_container'
      # These are inverse actions, execute them
      if action['action_type'] == 'delete_location'
        Location[action['params']['location_id']].delete
      elsif action['action_type'] == 'delete_connection'
        Connection[action['params']['connection_id']].delete
      elsif action['action_type'] == 'delete_character'
        Character[action['params']['character_id']].delete
      elsif action['action_type'] == 'delete_item'
        Item[action['params']['item_id']].delete
      elsif action['action_type'] == 'delete_container'
        Container[action['params']['container_id']].delete
      end
    when 'restore_location'
      Location.create(action['params'].transform_keys(&:to_sym))
    when 'restore_connection'
      Connection.create(action['params'].transform_keys(&:to_sym))
    when 'restore_character'
      Character.create(action['params'].transform_keys(&:to_sym).merge(character_type: 'npc'))
    when 'restore_item'
      Item.create(action['params'].transform_keys(&:to_sym))
    when 'restore_container'
      Container.create(action['params'].transform_keys(&:to_sym))
    end

    # Add to redo stack
    redo_stack << action

    { success: true, undo_available: undo_stack.any?, redo_available: redo_stack.any? }.to_json
  rescue => e
    puts "Undo error: #{e.message}"
    { error: e.message }.to_json
  end
end

# World Builder - Redo
post '/worlds/builder/:id/redo' do
  user = current_user
  halt 401 unless user

  world_id = params[:id].to_i
  world = World[world_id]

  halt 404 unless world
  halt 403 unless world.is_template

  content_type :json

  session[:world_actions] ||= {}
  session[:world_actions][world_id.to_s] ||= { undo_stack: [], redo_stack: [] }

  undo_stack = session[:world_actions][world_id.to_s][:undo_stack]
  redo_stack = session[:world_actions][world_id.to_s][:redo_stack]

  if redo_stack.empty?
    halt 400, { error: "Nothing to redo" }.to_json
  end

  action = redo_stack.pop

  # Re-execute the original action (inverse of the undo)
  begin
    case action['action_type']
    when 'delete_location', 'delete_connection', 'delete_character', 'delete_item', 'delete_container'
      if action['action_type'] == 'delete_location'
        Location[action['params']['location_id']].delete
      elsif action['action_type'] == 'delete_connection'
        Connection[action['params']['connection_id']].delete
      elsif action['action_type'] == 'delete_character'
        Character[action['params']['character_id']].delete
      elsif action['action_type'] == 'delete_item'
        Item[action['params']['item_id']].delete
      elsif action['action_type'] == 'delete_container'
        Container[action['params']['container_id']].delete
      end
    when 'restore_location'
      Location.create(action['params'].transform_keys(&:to_sym))
    when 'restore_connection'
      Connection.create(action['params'].transform_keys(&:to_sym))
    when 'restore_character'
      Character.create(action['params'].transform_keys(&:to_sym).merge(character_type: 'npc'))
    when 'restore_item'
      Item.create(action['params'].transform_keys(&:to_sym))
    when 'restore_container'
      Container.create(action['params'].transform_keys(&:to_sym))
    end

    # Add back to undo stack
    undo_stack << action

    { success: true, undo_available: undo_stack.any?, redo_available: redo_stack.any? }.to_json
  rescue => e
    puts "Redo error: #{e.message}"
    { error: e.message }.to_json
  end
end

# Logout
post '/logout' do
  session.clear
  redirect '/login'
end

# Game Engine endpoint - unified interface for all game operations
post '/game-engine' do
  user = current_user
  halt 401, { error: 'Authentication required' }.to_json unless user

  content_type :json

  # Parse request body
  request.body.rewind
  data = JSON.parse(request.body.read)

  action = data['action']
  params = data['params'] || {}

  halt 400, { error: 'Action is required' }.to_json unless action

  # Verify user has access to the room if room_id is provided
  if params['room_id']
    room_id = params['room_id'].to_i
    access = DB[:user_rooms].where(user_id: user[:id], room_id: room_id).first
    halt 403, { error: 'Access denied to this room' }.to_json unless access
  end

  # Check if the game engine responds to this action
  unless game_engine.respond_to?(action)
    halt 400, { error: "Unknown action: #{action}" }.to_json
  end

  begin
    # Convert string keys to symbols for cleaner method calls
    symbol_params = params.transform_keys(&:to_sym)

    # Call the game engine method with params as keyword arguments if it expects them
    # Otherwise call with regular arguments
    method = game_engine.method(action)

    result = if method.arity == 0
      game_engine.send(action)
    elsif method.parameters.any? { |type, _| type == :keyreq || type == :key }
      game_engine.send(action, **symbol_params)
    else
      # Convert params hash values to an array in the order the method expects
      args = method.parameters.map { |_, name| symbol_params[name] }
      game_engine.send(action, *args.compact)
    end

    # Return the result
    result.to_json
  rescue => e
    puts "Game engine error: #{e.message}"
    puts e.backtrace.join("\n")
    { error: e.message }.to_json
  end
end

# World Builder AI - Clear conversation
post '/worlds/builder/:id/clear-conversation' do
  user = current_user
  halt 401 unless user

  world_id = params[:id].to_i
  world = World[world_id]
  halt 404 unless world && world.is_template

  # Delete conversation history
  DB[:world_builder_conversations].where(world_id: world_id).delete

  # Reinitialize AI
  settings.world_builder_mutex.synchronize do
    if settings.world_builder_ais[world_id]
      settings.world_builder_ais[world_id] = WorldBuilderAI.new(
        world_id,
        DB,
        settings.sockets,
        settings.sockets_mutex,
        restore: false
      )
    end
  end

  redirect "/worlds/builder/#{world_id}"
end

# World Builder AI - Approve entities
post '/worlds/builder/:id/approve' do
  user = current_user
  halt 401 unless user

  world_id = params[:id].to_i
  world = World[world_id]
  halt 404 unless world && world.is_template

  content_type :json

  # Parse JSON body
  request.body.rewind
  data = JSON.parse(request.body.read)

  request_id = data['request_id']
  approved = data['approved']

  ai = settings.world_builder_ais[world_id]
  if ai
    ai.handle_approval_response(request_id, approved)
    { success: true }.to_json
  else
    { error: 'AI not initialized' }.to_json
  end
end

# World Builder AI - WebSocket endpoint
get '/ws/builder' do
  user = current_user
  halt 401, "Authentication required" unless user

  world_id = params[:world_id]&.to_i
  halt 400, "World ID required" unless world_id

  # Verify world exists and is a template
  world = World[world_id]
  halt 404, "World not found" unless world && world.is_template

  if Faye::WebSocket.websocket?(request.env)
    ws = Faye::WebSocket.new(request.env)

    ws.on :open do |event|
      settings.sockets_mutex.synchronize do
        settings.sockets["builder_#{world_id}"] ||= []
        settings.sockets["builder_#{world_id}"] << ws
        puts "[WorldBuilderAI] Client connected to world #{world_id}"
      end
    end

    ws.on :message do |event|
      data = JSON.parse(event.data)

      if data['type'] == 'builder_message'
        ai = settings.world_builder_ais[world_id]
        if ai
          context = data['context'] # Optional focused entity context
          Thread.new { ai.handle_user_message(user[:id], data['message'], context: context) }
        end
      elsif data['type'] == 'approval_response'
        ai = settings.world_builder_ais[world_id]
        if ai
          Thread.new { ai.handle_approval_response(data['request_id'], data['approved']) }
        end
      end
    end

    ws.on :close do |event|
      settings.sockets_mutex.synchronize do
        settings.sockets["builder_#{world_id}"]&.delete(ws)
        puts "[WorldBuilderAI] Client disconnected from world #{world_id}"
      end
    end

    ws.rack_response
  else
    status 400
    "WebSocket connection required"
  end
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
      settings.sockets_mutex.synchronize do
        settings.sockets[room_id] ||= []
        settings.sockets[room_id] << ws
        puts "Client connected: #{user[:username]} to room #{room_id}. Room total: #{settings.sockets[room_id].length}"
      end
    end

    ws.on :message do |event|
      message = JSON.parse(event.data)
      message_text = message['message']
      data_json = '{}'

      # Check if user is muted
      user_room = DB[:user_rooms].where(user_id: user[:id], room_id: room_id).first
      if user_room && user_room[:is_muted]
        # Silently ignore messages from muted users
        next
      end

      # Check if this is a dice roll command
      if message_text =~ /^\/roll\s+(.+)/
        dice_command = $1

        begin
          # Use DiceRoll class to roll the dice
          dice_roll = DiceRoll.new(dice_command)

          # Prepare data to store
          data = {
            type: 'dice_roll',
            command: dice_command,
            result_dice: dice_roll.result_dice,
            modifiers: dice_roll.modifiers,
            dice_total: dice_roll.result_dice.sum(&:first),
            total: dice_roll.total
          }

          data_json = JSON.generate(data)
          message_text = '' # Clear the message text for dice rolls
        rescue => e
          puts "Dice roll error: #{e.message}"
          # If there's an error, treat it as a normal message
        end
      end

      # Save message to database
      DB[:chat_messages].insert(
        room_id: room_id,
        user_id: user[:id],
        message: message_text,
        data: data_json
      )

      # Render message HTML
      message_html = render_message(user[:id], user[:username], message_text, room_id, is_own: false, data: data_json)

      # Prepare broadcast message
      broadcast_data = {
        html: message_html,
        user_id: user[:id]
      }

      # Broadcast message to ALL clients in the same room (including sender)
      settings.sockets_mutex.synchronize do
        if settings.sockets[room_id]
          settings.sockets[room_id].each do |socket|
            socket.send(JSON.generate(broadcast_data))
          end
        end
      end

      # Notify AI Game Master if applicable and not from AI
      unless user[:is_ai]
        ai_gm = settings.ai_game_masters[room_id]
        if ai_gm
          # Parse data if it exists
          parsed_data = nil
          if data_json && data_json != '{}'
            parsed_data = JSON.parse(data_json)
          end

          Thread.new { ai_gm.handle_player_message(user[:username], message_text, parsed_data) }
        end
      end
    end

    ws.on :close do |event|
      settings.sockets_mutex.synchronize do
        if settings.sockets[room_id]
          settings.sockets[room_id].delete(ws)
          puts "Client disconnected: #{user[:username]} from room #{room_id}. Room total: #{settings.sockets[room_id].length}"
          # Clean up empty room arrays
          settings.sockets.delete(room_id) if settings.sockets[room_id].empty?
        end
      end
    end

    # Return async Rack response
    ws.rack_response
  else
    status 400
    "WebSocket connection required"
  end
end
