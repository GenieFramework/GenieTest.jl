
@testitem "App without frontend" setup = [Setup] tags=[:ci, :no_frontend] begin
    using Stipple.ReactiveTools: @set

    port = rand(8081:8999)
    down()
    up(port)
    app = App("/", frontend = :none)
    @test app.list[1] == 1
    app.list[1] = 2
    @test app.list[1] == 2
    # call was not notifying, so :y should stay the same
    @test app.y[1] == 10
    notify(app, :list)
    @test app.y[1] == 3
    # now set with the new `@set` macro
    @set app.list[1] = 4
    @test app.y[1] == 5
    
    down()
end