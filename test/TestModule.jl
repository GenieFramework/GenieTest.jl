@testmodule TestModule begin

using GenieTest
export wait_for, notify_test, App, GenieTest

using Stipple, Stipple.ReactiveTools
using StippleUI
Stipple.enable_model_storage(false)

cd(dirname(@__DIR__))

println("\n\n\nStarting Test")
println("in directory ", pwd(), "\n")

@app MyApp begin
    @in x = "World"
    
    @onchange x println("x: $x")
    @onchange isready @info "Ready!"
end

ui() = [htmldiv("Hello"), textfield(style = "max-width: 60px", "", :x)]

@page("/", ui, title = "GenieTest", model = MyApp)

end


@testitem "Module Test" setup = [GTModule] begin
    @test GenieTest.App isa DataType
end