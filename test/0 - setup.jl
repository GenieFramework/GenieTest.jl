@testmodule Setup begin
    using GenieTest
    export wait_for, notify_test, App, GenieTest

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
        
        @onchange x println("x: $x")
        @onchange isready @info "Ready!"
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