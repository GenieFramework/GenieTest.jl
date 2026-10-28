@testmodule Setup begin
    using GenieTest
    using Electron
    export wait_for, notify_test, App, GenieTest, assert_connection!

    using Genie
    export up, down
    using Stipple, Stipple.ReactiveTools
    using StippleUI
    using StippleUI.FormInputs: textfield

    Stipple.enable_model_storage(false)

    cd(dirname(@__DIR__))

    println("\n\n\nStarting Test")
    println("in directory ", pwd(), "\n")

    @app MyApp begin
        @in x = "World"
        
        @in pinged = 0
        @in ping_info = ""

        @onchange x println("x: $x")
        @onchange isready @info "Ready!"
    end

    @event MyApp :ping begin
        pinged += 1
        ping_info = string(event)
    end

    ui() = [htmldiv("Hello"), textfield(style = "max-width: 60px", "", :x)]

    @page("/", ui, title = "GenieTest", model = MyApp)
end


@testitem "Module Test" setup = [Setup] begin
    @test GenieTest.App isa DataType
end

@testitem "Client field access" setup = [Setup] tags=[:ci] begin
    client = Client()
    client.__fields__["value"] = 1
    @test client.value == 1

    app = App(__frontend__ = client)
    @test app.value == 1
    @test app.__frontend__ === client
    @test app.__window__ === nothing

    summary = sprint(show, client)
    @test startswith(summary, "GenieTest.Client(")
    @test occursin("1 model field", summary)
    @test !occursin("__cookies__", summary)
end

@testitem "wait_for with a client" setup = [Setup] tags=[:ci] begin
    client = Client()
    fields = getfield(client, :__fields__)
    condition = getfield(client, :__changed__)
    update(value) = lock(condition) do
        fields["a"] = value
        notify(condition; all = true)
    end

    @test wait_for(() -> false, client; timeout = 0.2) === false
    @test wait_for(() -> false, client; timeout = 0.2, success = :ok, fail = :failed) === :failed

    @async (sleep(0.2); update(1))
    t0 = time()
    @test wait_for(() -> GenieTest.getfield_(client, "a") == 1, client; timeout = 5)
    @test time() - t0 < 2

    # via the app
    app = App(__frontend__ = client)
    @async (sleep(0.2); update(2))
    @test wait_for(() -> app.a == 2, app; timeout = 5)
    @test wait_for(() -> app.a == 3, app; timeout = 0.2) === false
end

@testitem "wait_for polling" setup = [Setup] tags=[:ci] begin
    n = Ref(0)
    @test wait_for(() -> (n[] += 1) >= 3; timeout = 5, delay = 0.01)
    @test wait_for(() -> false; timeout = 0.1, delay = 0.01) === false
end

@testitem "Unreachable client" setup = [Setup] tags=[:ci] begin
    client = Client("http://127.0.0.1:1")
    @test GenieTest.connect!(client; timeout = 1) === false
    @test !is_connected(client)

    app = App(__frontend__ = client)
    @test assert_connection!(app; timeout = 1) === false
end

@testitem "Client against a live server" setup = [Setup] tags=[:ci] begin
    port = 8765
    up(port)
    try
        app = App("/"; frontend = :client, backend = false, port, timeout = 30)
        client = app.__frontend__
        @test client isa Client
        @test is_connected(client)
        @test assert_connection!(app)
        @test GenieTest.connect!(client)
        @test wait_for(() -> app.x == "World", app; timeout = 10)
        @test_throws ErrorException trigger_event(app, :ping; via = :backend)
        close(client)
        @test !is_connected(client)
    finally
        down()
    end
end

@testitem "App priority" setup = [Setup] tags=[:ci] begin
    @test_throws ArgumentError App(__priority__ = :fronted)

    model = Stipple.ReactiveTools.init_model(Setup.MyApp)
    client = Client()
    getfield(client, :__fields__)["x"] = "from client"

    app = App(__model__ = model, __frontend__ = client)
    @test app.__priority__ === :backend
    @test GenieTest.access_target(app) === :model
    model.x[] = "from model"
    @test app.x == "from model"
    app.x = "set via model"
    @test model.x[] == "set via model"
    @test client.x == "from client"

    app.__priority__ = :frontend
    @test GenieTest.access_target(app) === :frontend
    @test app.x == "from client"
    @test :x ∈ propertynames(app)
    @test_throws ArgumentError (app.__priority__ = :nonsense)

    # without a model the frontend is used regardless of the priority
    app.__priority__ = :backend
    app.__model__ = nothing
    @test GenieTest.access_target(app) === :frontend
    @test app.x == "from client"

    @test GenieTest.access_target(App()) === :none
end


@testitem "Trigger events" setup = [Setup] tags=[:ci] begin
    @test_throws ArgumentError trigger_event(App(), :ping; via = :nowhere)
    @test_throws ErrorException trigger_event(App(), :ping)

    port = 8766
    up(port)
    try
        # backend and headless client attached to the same model
        app = App("/"; frontend = :client, backend = true, port, timeout = 30)
        @test app.__model__ !== nothing && app.__frontend__ isa Client

        n = app.pinged
        @test trigger_event(app, :ping, "direct"; via = :backend)
        @test app.pinged == n + 1
        @test app.ping_info == "direct"

        # round trip through the frontend; the backend is used to inspect the result
        @test trigger_event(app, "ping", Dict("a" => 1); via = :frontend)
        # ping_info is set after pinged, so wait for both
        @test wait_for(() -> app.pinged == n + 2 && occursin("a", app.ping_info), app; timeout = 10)

        # :auto follows the priority
        app.__priority__ = :frontend
        @test trigger_event(app, :ping)
        @test wait_for(() -> app.pinged == n + 3, app; timeout = 10, delay = 0.05)
    finally
        down()
    end
end
