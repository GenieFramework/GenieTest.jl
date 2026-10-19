@testitem "Frontend Test" setup = [Setup] tags=[:frontend] begin
    port = rand(8081:8999)
    down()
    up(port = port, ws_port = port)

    app = App("/"; frontend = :electron, port)

    test_str = "John"
    app.x = test_str
    sleep(0.5)
    result = @test run(app, "GENIEMODEL.x") == test_str
    notify_test(app, result, "Setting greeting")
    
    sleep(3)
    close(app)
end

@testitem "Trigger events from an Electron window" setup = [Setup] tags=[:frontend] begin
    port = rand(8081:8999)
    down()
    up(port = port, ws_port = port)

    app = App("/"; frontend = :electron, port)
    try
        n = app.pinged
        @test trigger_event(app, :ping, Dict("a" => 1); via = :frontend)
        @test wait_for(() -> app.pinged == n + 1, app; timeout = 10)
        @test occursin("a", app.ping_info)

        app.__priority__ = :frontend
        @test trigger_event(app, "ping")
        @test wait_for(() -> app.__model__.pinged[] == n + 2, app; timeout = 10)
    finally
        close(app)
        down()
    end
end
