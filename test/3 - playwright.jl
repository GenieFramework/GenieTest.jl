# Needs the (unregistered) Playwright package and a Chrome installation, therefore not part of the :ci tests.
@testitem "Playwright frontend" setup = [Setup] tags=[:playwright] begin
    using Playwright
    port = rand(8081:8999)
    down()
    up(port = port, ws_port = port)

    app = App("/"; frontend = :playwright, port, frontend_options = Dict(:headless => true, :profile => mktempdir()))
    try
        @test GenieTest.is_usable(app.__frontend__)
        @test app.__window__ === nothing

        app.x = "John"
        @test wait_for(() -> run(app, "GENIEMODEL.x") == "John", app; timeout = 10)
        @test app["x"] == "John"

        # numbers come back as Int
        @test run(app, "1 + 1") === 2

        n = app.pinged
        @test trigger_event(app, :ping, Dict("a" => 1); via = :frontend)
        @test wait_for(() -> app.pinged == n + 1 && occursin("a", app.ping_info), app; timeout = 10)

        @test notify(app, "hello")

        # a closed page is recreated by assert_connection!
        close(app.__frontend__)
        @test !GenieTest.is_usable(app.__frontend__)
        @test assert_connection!(app)
        @test GenieTest.is_usable(app.__frontend__)
    finally
        close(app)
        down()
    end
end

@testitem "Playwright frontends share the browser of a profile" setup = [Setup] tags=[:playwright] begin
    using Playwright
    ext = Base.get_extension(GenieTest, :GenieTestPlaywrightExt)
    port = rand(8081:8999)
    down()
    up(port = port, ws_port = port)

    options = Dict(:headless => true, :profile => mktempdir())
    app = App("/"; frontend = :playwright, port, frontend_options = options)
    app2 = App("/"; frontend = :playwright, port, frontend_options = options)
    try
        @test app.__frontend__.__context__ === app2.__frontend__.__context__
        @test app.__frontend__.__page__ !== app2.__frontend__.__page__
        @test GenieTest.is_usable(app.__frontend__) && GenieTest.is_usable(app2.__frontend__)

        # closing one app leaves the other one usable
        close(app)
        @test !GenieTest.is_usable(app.__frontend__)
        @test run(app2, "1 + 1") === 2
    finally
        close(app)
        close(app2)
        down()
    end
    @test isempty(ext.SESSIONS)
end
