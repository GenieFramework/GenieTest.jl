@testitem "Frontend Test" setup = [TestModule] begin
    using GenieTest

    port = rand(8081:8999)
    down()
    up(port = port, ws_port = port)

    app = App("/"; frontend = :electron, port)
    try
        test_str = "John"
        app.x = test_str
        sleep(0.5)
        result = @test run(app.__window__, "GENIEMODEL.x") == test_str
        notify_test(app, result, "Setting greeting")
        
        sleep(3)
    finally
        close(app)
    end
end