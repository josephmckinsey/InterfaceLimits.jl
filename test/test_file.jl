using PowerSystems
using PowerNetworkMatrices
using DataFrames
using HiGHS

@testset "find_interface_limits on RTS-GMLC" begin
    solver = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false)

    sys = System(
        joinpath(
            dirname(dirname(pathof(InterfaceLimits))),
            "examples",
            "rts",
            "RTS-GMLC.RAW",
        ),
    )
    set_units_base_system!(sys, "natural_units")


    @testset "Basic interface test" begin
        df = find_interface_limits(sys, solver)

        @test df isa DataFrame
        @test names(df) == ["interface", "transfer_limit", "sum_capacity"]
        @test nrow(df) > 0
        @test all(df.transfer_limit .>= 0)
        @test all(df.transfer_limit .<= df.sum_capacity .+ 1e-6)
        # interface capacities in MW, since the system is in natural units
        capacity_mw = Dict(
            "1_2" => 1175.0, "2_1" => 1175.0,
            "1_3" => 500.0, "3_1" => 500.0,
            "2_3" => 500.0, "3_2" => 500.0,
        )
        @test all(df.sum_capacity .≈ getindex.(Ref(capacity_mw), df.interface))
        @test string(get_units_base(sys)) == "NATURAL_UNITS"
    end

    @testset "n-1 interface limits (security=true)" begin
        @info "calculating n-1 interface limits"
        df = find_interface_limits(sys, solver, security=true)

        @test df isa DataFrame
        @test names(df) == ["interface", "transfer_limit", "sum_capacity"]
        @test nrow(df) > 0
        @test all(df.transfer_limit .>= 0)
        @test all(df.transfer_limit .<= df.sum_capacity .+ 1e-6)
        @test string(get_units_base(sys)) == "NATURAL_UNITS"
    end

    interfaces = InterfaceLimits.find_interfaces(sys)
    interface_key = first(collect(keys(interfaces)))
    interface = interfaces[interface_key]

    @testset "calculating n-0 interface limits for just 1 interface" begin
        interface_lims =
            find_interface_limits(sys, solver, interface_key, interface)
        interface_lims = find_interface_limits(
            sys,
            solver,
            interface_key,
            interface,
            security=true,
        )
        @test interface_lims isa DataFrame
        @test names(interface_lims) == ["interface", "transfer_limit", "sum_capacity"]
        @test nrow(interface_lims) > 0
        @test all(interface_lims.transfer_limit .>= 0)
    end

    @testset "custom interface limits (with n-1)" begin
        interface_lims = find_interface_limits(
            sys,
            solver,
            interface_key,
            interface,
            security=true,
            injection_limits=InjectionLimits(genbus_upper_bound=5.0, loadbus_bounds=(0.0, 2.0), enforce_ldfs=true),
        )
        @test interface_lims isa DataFrame
        @test names(interface_lims) == ["interface", "transfer_limit", "sum_capacity"]
        @test nrow(interface_lims) > 0
        @test all(interface_lims.transfer_limit .>= 0)
    end
end

@testset "three-winding transformer across areas" begin
    solver = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false)
    sys = System(
        joinpath(
            dirname(dirname(pathof(InterfaceLimits))),
            "examples",
            "rts",
            "RTS-GMLC.RAW",
        ),
    )
    # One winding in each area, star bus in area 1
    b1, b2, b3 = get_bus(sys, 101), get_bus(sys, 201), get_bus(sys, 301)
    star = ACBus(;
        number = 999,
        name = "star",
        available = true,
        bustype = ACBusTypes.PQ,
        angle = 0.0,
        magnitude = 1.0,
        voltage_limits = (min = 0.9, max = 1.1),
        base_voltage = get_base_voltage(b1),
        area = get_area(b1),
    )
    add_component!(sys, star)
    add_component!(
        sys,
        Transformer3W(;
            name = "t3w",
            available = true,
            primary_star_arc = Arc(b1, star),
            secondary_star_arc = Arc(b2, star),
            tertiary_star_arc = Arc(b3, star),
            star_bus = star,
            active_power_flow_primary = 0.0,
            reactive_power_flow_primary = 0.0,
            active_power_flow_secondary = 0.0,
            reactive_power_flow_secondary = 0.0,
            active_power_flow_tertiary = 0.0,
            reactive_power_flow_tertiary = 0.0,
            r_primary = 0.001,
            x_primary = 0.05,
            r_secondary = 0.001,
            x_secondary = 0.05,
            r_tertiary = 0.001,
            x_tertiary = 0.05,
            rating = 1.0,
            r_12 = 0.002,
            x_12 = 0.1,
            r_23 = 0.002,
            x_23 = 0.1,
            r_13 = 0.002,
            x_13 = 0.1,
            base_power_12 = 100.0,
            base_power_23 = 100.0,
            base_power_13 = 100.0,
        ),
    )
    set_units_base_system!(sys, "natural_units")

    # The transformer is not part of any interface or monitored branch set
    interfaces = InterfaceLimits.find_interfaces(sys)
    @test !any(br isa ThreeWindingTransformer for brs in values(interfaces) for br in brs)
    lines, buses = InterfaceLimits.find_neighbor_lines(sys, "1" => "2", get_available, 1)
    @test !any(br isa ThreeWindingTransformer for br in lines)
    # but its windings still connect buses when searching for neighbors
    @test star ∈ buses
    @test b3 ∈ buses

    df = find_interface_limits(sys, solver; security = true)
    @test nrow(df) == 6
    @test all(df.transfer_limit .>= 0)
    @test all(df.transfer_limit .<= df.sum_capacity .+ 1e-6)
end
