cd(dirname(@__DIR__))

using Test, TestItemRunner

@run_package_tests filter = ti -> (:ci in ti.tags)

@testitem "GenieTest tests" begin
    @test 1 + 1 == 2
end

@testitem "App without frontend" tags=[:ci, :no_frontend] begin
    @app MyApp begin
        @in x = [1, 2, 3, Dict(1 => 1, 2 => 2)]
        @in y = 10
        @onchange x begin
            println("x: $x")
            @notify("Message to UI: $x")
            y = x[1] + 1
        end
    end

    @page("/", "x: {{x}}", model = MyApp)

    port = rand(8081:8999)
    up(port)
    app = App("/", frontend = :none)
    @test app.x[1] == 1
    app.x[1] = 2
    @test app.x[1] == 2
    # call was not notifying, so :y should stay the same
    @test app.y[1] == 10
    notify(app, :x)
    @test app.y[1] == 3
    # now set with the new `@set` macro
    @set app.x[1] = 4
    @test app.y[1] == 5
    
    down()
end