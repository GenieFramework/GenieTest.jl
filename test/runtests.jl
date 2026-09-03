cd(dirname(@__DIR__))

using Test, TestItemRunner

@run_package_tests filter = ti -> (:ci in ti.tags)