cd(dirname(@__DIR__))

using Test, TestItemRunner

@testitem "GenieTest tests" begin
    @test 1 + 1 == 2
end