using ProtoSyn
using Printf

function print_energy_components(driver::String, step::Int64, energy::Common.Energy, temp::Float64)
    components = [:amber, :contacts, :sol, :hb]
    s = @sprintf("%10s %6d %11.4e", driver, step, energy.total)
    for component in components
        c = component in keys(energy.components) ? energy.components[component] : 0.0
        s = join([s, @sprintf("%11.4e", c)], " ")
    end
    s = join([s, @sprintf("| %6.3f", temp)], " ")
    return s
end

function print_energy_keys(driver::String, step::Int64, energy::Common.Energy)
    components = [:amber, :contacts, :sol, :hb]
    s = @sprintf("%10s %6d %11s", driver, step, "TOTAL")
    for key in components
        s = join([s, @sprintf("%11s", uppercase(string(key)))], " ")
    end
    s = join([s, " | TEMPERATURE"])
    return s
end

#= -------------------------------------------------
2. Simulated Annealing Example

# Algorithm explanation:
The Simulated Annealing algorithm searches the local conformational space,
mutating the structure or nature of the molecules in the simulation.
Configurations are accepted or not based on the Metropolis criterium.
However, differing from a simple Monte Carlo, the temperature of system
is gradually lowered until 0, so that, in theory, a single local optimum is
identified.

# New ProtoSyn concepts:
- Coumpound Mutators
-------------------------------------------------=#

# Configuration
input_pdb                = "data/1i2t_native.pdb"
input_amber_top          = "data/1i2t_amber_top.json"
hydrogen_bonding_library = "data/sc_hb_lib.json"
rotamer_library          = "data/rotamer_library.json"
ss                       = "CHHHHHHHHHHHHHHHCCCCHHHHHHHHHHCCHHHHHHHHHCHHHHHHHHHHHHHHHHHHC"

# System Set-up & Loading
state, metadata = Common.load_from_pdb(input_pdb)
sidechains      = Common.compile_sidechains(metadata.dihedrals)
Common.compile_ss_blocks_metadata!(metadata, ss)
# Common.apply_ss!(state, metadata, ss)

# Component A: Amber forcefield
amber_top = Forcefield.Amber.load_from_json(input_amber_top)

# Component B: Coarse-grain solvation energy
solv_pairs = Forcefield.CoarseGrain.compile_solv_pairs(
    metadata.dihedrals,
    λ = 1.0
)

# Component C: Coarse-grain hydrogen bonding network
hb_network = Forcefield.CoarseGrain.compile_hb_network(
    metadata.atoms,
    lib = Aux.read_JSON(hydrogen_bonding_library),
    λ = 1.0)

# Component D: Dihedral restraints
dihedral_restraints = Forcefield.Restraints.lock_block_bb(metadata,
    fbw = 10.0,
    λ = 100.0)

# Evaluators: An evaluator aggregates all defined components
custom_evaluator = Forcefield.Evaluator(
    components = [amber_top, solv_pairs, hb_network, dihedral_restraints])

# Mutators
sidechain_mutator   = Mutators.Sidechain.MutatorConfig(
    sidechains = sidechains,
    rot_lib = Aux.read_JSON(rotamer_library),
    p_mut = 0.1)
    
# Coumpound Mutators
#=
* Note: In this example, Blockrot Mutator is a Coumpound Mutator. This means
that, for it to function, it requires to receive another Mutator and/or Driver
as a parameter. For Blockrot Mutator, after a secondary structure block is
rotated/translated, the loops on each side need to be "re-closed". Altough
there are multiple ways of doing it, this example will employ Steepest Descent
to try and close the loops.
=#

sd_evaluator = Forcefield.Evaluator(components = [amber_top, dihedral_restraints])

print_status_min = Common.@callback 200 function (st::Common.State, dr_state)
    @printf("%15s %5d: %10.3e %10.3e\n", "Minimizing...", dr_state.step, st.energy.total, dr_state.step_size)
end

sd_minimizer = Drivers.SteepestDescent.DriverConfig(
    evaluator   = sd_evaluator,
    n_steps     = 2000,
    nblist_freq = 50,
    f_tol       = 0.2,
    max_step    = 0.01,
    callbacks   = [print_status_min])

blockrot_mutator = Mutators.Blockrot.MutatorConfig(
    blocks = metadata.blocks,
    angle_sampler = () -> (randn() * blockrot_mutator.step_size),
    p_mut = 0.4,
    step_size = π/36,
    translation_step_size = 0.0,
    n_tries = 50,
    rot_axis = :longitudinal,
    loop_closer = sd_minimizer)
    
# Sampler
custom_sampler = Mutators.Sampler(mutators = [blockrot_mutator])

# Callbacks
print_status_sa = Common.@callback 1 function (state, dr_state)
    println(print_energy_components("MonteCarlo", dr_state.step, state.energy, dr_state.temperature))

end

print_struct_sa = Common.@callback 1 function (state, dr_state)
    Print.as_pdb(output_file, state, metadata)
    flush(output_file)
end

n_steps = 100_000
i_temp = 70.0
function adjust_temperature(step::Int64)
    return -(i_temp/n_steps) * step + i_temp
end
sa_driver = Drivers.MonteCarlo.DriverConfig(
    sampler = custom_sampler,
    evaluator = custom_evaluator,
    temperature = adjust_temperature,
    n_steps = n_steps,
    callbacks = [print_status_sa, print_struct_sa])

if ""!=PROGRAM_FILE && realpath(@__FILE__) == realpath(PROGRAM_FILE)
    const output_file = open("6_refinement.pdb", "w")

    println("Refinement example:")
    Drivers.run!(state, sd_minimizer)
    @time Drivers.run!(state, sa_driver)
end