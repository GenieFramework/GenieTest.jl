mutable struct Client
    __base__::String
    __page__::String
    __cookies__::Dict{String,String}
    __channel__::String
    __sesstoken__::String
    __fields__::JSON.Object{String,Any}
    __ws__::Any
    __task__::Union{Task,Nothing}
    __ready__::Bool
    __changed__::Threads.Condition
    __log__::Vector{String}
end

function Client(url::Union{AbstractString,URI} = "http://127.0.0.1:8000")
    uri = URI(url)
    port = uri.port === nothing ? "" : ":$(uri.port)"
    base = string(uri.scheme, "://", uri.host, port)
    page = isempty(uri.path) ? "/" : uri.path
    isempty(uri.query) || (page *= "?$(uri.query)")
    Client(base, page, Dict{String,String}(), "", "", JSON.Object{String,Any}(),
           nothing, nothing, false, Threads.Condition(), String[])
end

function Base.getproperty(client::Client, fieldname::Symbol)
    field = String(fieldname)
    if startswith(field, "__") && endswith(field, "__")
        return getfield(client, fieldname)
    end
    fields = getfield(client, :__fields__)
    haskey(fields, field) || error("Field $(fieldname) does not exist in client.")
    lock(getfield(client, :__changed__)) do
        fields[field]
    end
end

function Base.setproperty!(client::Client, fieldname::Symbol, value)
    field = String(fieldname)
    if startswith(field, "__") && endswith(field, "__")
        return setfield!(client, fieldname, value)
    end
    setfield_!(client, field, value)
end

function Base.propertynames(client::Client, private::Bool = false)
    fields = getfield(client, :__fields__)
    public_fields = Tuple(Symbol(key) for key in keys(fields))
    private ? (public_fields..., fieldnames(Client)...) : public_fields
end

function Base.show(io::IO, client::Client)
    base = getfield(client, :__base__)
    page = first(split(getfield(client, :__page__), '?'))
    status = getfield(client, :__ready__) ? "ready" : "not connected"
    field_count = length(getfield(client, :__fields__))
    fields_label = field_count == 1 ? "model field" : "model fields"
    print(io, "GenieTest.Client(", repr(base * page), "; ", status, ", ", field_count, " ", fields_label, ")")
end

Base.show(io::IO, ::MIME"text/plain", client::Client) = show(io, client)

cookie_header(client::Client) = join(("$key=$value" for (key, value) in getfield(client, :__cookies__)), "; ")

function store_cookies!(client::Client, response)
    cookies = getfield(client, :__cookies__)
    for (key, value) in response.headers
        lowercase(key) == "set-cookie" || continue
        name, _, cookie = partition3(first(split(value, ';')))
        cookies[name] = cookie
    end
end

partition3(value) = (index = findfirst('=', value); index === nothing ? (value, "=", "") : (value[1:index-1], "=", value[index+1:end]))

function parse_model_defaults(js::AbstractString)
    marker = "\"data\":() => ("
    start = findfirst(marker, js)
    start === nothing && error("model data block not found")
    index = last(start) + 1
    js[index] == '{' || error("unexpected model data block")
    depth, in_string, escaped, cursor = 0, false, false, index
    while true
        character = js[cursor]
        if in_string
            escaped ? (escaped = false) : character == '\\' ? (escaped = true) : character == '"' && (in_string = false)
        elseif character == '"'
            in_string = true
        elseif character == '{'
            depth += 1
        elseif character == '}'
            depth -= 1
            depth == 0 && break
        end
        cursor = nextind(js, cursor)
    end
    JSON.parse(js[index:cursor])
end

const CLIENT_MODEL_DEFAULTS = Dict{String,JSON.Object{String,Any}}()
const CLIENT_MODEL_DEFAULTS_LOCK = ReentrantLock()

function model_defaults(client::Client, html::AbstractString, model_name::AbstractString)
    model_script = lowercase(model_name) * ".js"
    script_match = nothing
    for match_result in eachmatch(r"src=\"([^\"]+)\"", html)
        source = first(match_result.captures)
        if basename(first(split(source, '?'))) == model_script
            script_match = match_result
            break
        end
    end
    script_match === nothing && return JSON.Object{String,Any}()
    script = first(script_match.captures)
    url = startswith(script, "http") ? script : getfield(client, :__base__) * script
    lock(CLIENT_MODEL_DEFAULTS_LOCK) do
        get!(CLIENT_MODEL_DEFAULTS, url) do
            response = HTTP.get(url; cookies = false)
            parse_model_defaults(String(response.body))
        end
    end
end

function send_msg(client::Client, message, payload = Dict())
    HTTP.WebSockets.send(getfield(client, :__ws__),
                         JSON.json(Dict("channel" => getfield(client, :__channel__), "message" => message, "payload" => payload)))
end

send_watch(client::Client, field, value) = send_msg(client, "watchers",
    Dict("payload" => Dict("field" => field, "newval" => value, "oldval" => nothing, "sesstoken" => getfield(client, :__sesstoken__))))

function handle_message!(client::Client, message::AbstractString)
    message = strip(message)
    if startswith(message, "base64:")
        message = String(base64decode(strip(message[8:end])))
    end
    if message == "Subscription: OK"
        setfield!(client, :__ready__, true)
        send_watch(client, "isready", true)
    elseif startswith(message, "{") && endswith(message, "}")
        data = JSON.parse(message)
        if haskey(data, "key")
            lock(getfield(client, :__changed__)) do
                getfield(client, :__fields__)[data["key"]] = get(data, "value", nothing)
                notify(getfield(client, :__changed__); all = true)
            end
        end
    elseif startswith(message, ">eval:")
        push!(getfield(client, :__log__), message)
    end
end

"""
    connect!(client::Client; timeout = 15)

Load the page, connect to its WebChannel, and subscribe to the Stipple model.
"""
function connect!(client::Client; timeout = 15)
    response = HTTP.get(getfield(client, :__base__) * getfield(client, :__page__); cookies = false)
    store_cookies!(client, response)
    html = String(response.body)
    channel_match = match(r"create([A-Za-z0-9_]+)\('([A-Z0-9]+)'\)", html)
    channel_match === nothing && error("channel id not found in page")
    setfield!(client, :__channel__, String(channel_match.captures[2]))

    fields = getfield(client, :__fields__)
    merge!(fields, deepcopy(model_defaults(client, html, channel_match.captures[1])))
    token_match = match(r"name=\"sesstoken\" content=\"([^\"]*)\"", html)
    setfield!(client, :__sesstoken__, token_match === nothing ? "" : String(token_match.captures[1]))

    scheme = startswith(getfield(client, :__base__), "https") ? "wss" : "ws"
    wsurl = replace(getfield(client, :__base__), r"^https?" => scheme) * "/"
    opened = Channel{Bool}(1)
    setfield!(client, :__task__, @async try
        HTTP.WebSockets.open(wsurl; headers = ["Cookie" => cookie_header(client)]) do websocket
            setfield!(client, :__ws__, websocket)
            put!(opened, true)
            send_msg(client, "subscribe")
            for message in websocket
                handle_message!(client, message isa AbstractString ? message : String(message))
            end
        end
    catch exception
        exception isa InterruptException || push!(getfield(client, :__log__), "ws error: " * sprint(showerror, exception))
    finally
        setfield!(client, :__ready__, false)
        isopen(opened) && put!(opened, false)
    end)
    take!(opened) || error("websocket failed: " * join(getfield(client, :__log__), "; "))
    waitfor(() -> getfield(client, :__ready__), client; timeout, what = "subscription")
    client
end

function Base.close(client::Client)
    websocket = getfield(client, :__ws__)
    websocket === nothing || close(websocket)
    task = getfield(client, :__task__)
    task === nothing || wait(task)
    nothing
end

close!(client::Client) = close(client)

function setfield_!(client::Client, field::AbstractString, value)
    fields = getfield(client, :__fields__)
    send_watch(client, field, value)
    lock(getfield(client, :__changed__)) do
        fields[field] = value
    end
    value
end

function getfield_(client::Client, field::AbstractString, default = nothing)
    lock(getfield(client, :__changed__)) do
        get(getfield(client, :__fields__), field, default)
    end
end

"""
    waitfor(pred, client::Client; timeout = 10, what = "condition")

Wait for a client model update until `pred()` is true or the timeout expires.
"""
function waitfor(pred::Function, client::Client; timeout = 10, what = "condition")
    deadline = time() + timeout
    condition = getfield(client, :__changed__)
    lock(condition) do
        while !pred()
            remaining = deadline - time()
            remaining <= 0 && error("timeout waiting for $what")
            timer = Timer(remaining)
            @async (try
                wait(timer)
                lock(condition) do
                    notify(condition; all = true)
                end
            catch exception
                exception isa InterruptException || rethrow()
            end)
            wait(condition)
            close(timer)
        end
    end
    true
end

function login!(client::Client, nickname, password; timeout = 15)
    setfield_!(client, "nafnick", nickname)
    setfield_!(client, "password", password)
    setfield_!(client, "login_enter", true)
    waitfor(() -> (user_id = getfield_(client, "user_id", -1); user_id isa Integer && user_id > 0),
            client; timeout, what = "login of $nickname")
    getfield_(client, "user_id")
end

function logout!(client::Client; timeout = 10)
    setfield_!(client, "logout", true)
    waitfor(() -> getfield_(client, "user_id", 0) == -1, client; timeout, what = "logout")
end
