#  Copyright 2017, Oscar Dowson
#  This Source Code Form is subject to the terms of the Mozilla Public
#  License, v. 2.0. If a copy of the MPL was not distributed with this
#  file, You can obtain one at http://mozilla.org/MPL/2.0/.
#############################################################################

"""
    AbstractRiskMeasure

# Description

Abstract type for all risk measures.
"""
abstract type AbstractRiskMeasure end

"""
    AbstractCutOracle

# Description

Abstract type for all cut oracles.
"""
abstract type AbstractCutOracle end
abstract type AbstractValueFunction end

abstract type OptimisationSense end
struct Max <: OptimisationSense end
struct Min <: OptimisationSense end

abstract type IterationDirection end
struct ForwardPass <: IterationDirection end
struct BackwardPass <: IterationDirection end

abstract type SDDPSolveType end
"""
    Serial()

# Define

Type used to dispatch the serial solution algorithm
"""
struct Serial <: SDDPSolveType end
Base.show(io::IO, async::Serial) = print(io, "Serial solver")


const LinearConstraint=JuMP.ConstraintRef{JuMP.Model, JuMP.GenericRangeConstraint{JuMP.GenericAffExpr{Float64, JuMP.Variable}}}

mutable struct CachedVector{T} <: AbstractArray{T, 1}
    data::Vector{T}
    n::Int
end

struct Cut
    intercept::Float64
    coefficients::Vector{Float64}
end

struct State
    variable::JuMP.Variable
    constraint::LinearConstraint
end

mutable struct Noise
    has_objective_noise::Bool
    obj::Union{QuadExpr, AffExpr}
    # list of row indices
    constraints::Vector{LinearConstraint}
    # list of RHS values
    values::Vector{Float64}
end

struct SubproblemExt{S<:OptimisationSense, V<:AbstractValueFunction, R<:AbstractRiskMeasure}
    finalstage::Bool        # if final stage
    stage::Int              # stage index
    markovstate::Int        # index of the subproblem by markov state
    problembound::Float64   # objective bound
    sense::S          # optimisation sense (max or min)
    # a vector of states
    states::Vector{State}
    # an oracle to value function
    valueoracle::V
    # vector of noises
    noises::Vector{Noise}
    # probability[i] = probability of noises[i] occuring
    noiseprobability::Vector{Float64}
    # A risk measure to use for the subproblem
    riskmeasure::R
end

function Subproblem(;finalstage=false, stage=1, markov_state=1, sense=Min(), bound=-1e6,
    risk_measure=Expectation(), value_function=DefaultValueFunction(DefaultCutOracle()))
    m = Model()
    m.ext[:SDDP] = SDDP.SubproblemExt(
        finalstage,
        stage,
        markov_state,
        bound,
        sense,
        State[],
        initializevaluefunction(deepcopy(value_function), m, sense, bound),
        Noise[],
        Float64[],
        risk_measure
    )
    m
end

struct Stage
    t::Int
    # vector of subproblems in this stage
    subproblems::Vector{JuMP.Model}
    # transitionprobabilities[i, j] =
    # probability of transitioning from subproblem i to subproblem j in next stage
    transitionprobabilities::Array{Float64, 2}
    # storage for state on forward pass
    state::Vector{Float64}
    # extension dictionary
    ext::Dict
end
Stage(t=1, transition=Array{Float64}(0,0)) = Stage(t, JuMP.Model[], transition, Float64[], Dict())

struct Storage
    state::Vector{Float64}
    noise::CachedVector{Int}
    markov::CachedVector{Int}
    duals::CachedVector{Vector{Float64}}
    objective::CachedVector{Float64}
    probability::CachedVector{Float64}
    modifiedprobability::CachedVector{Float64}
end
Storage() = Storage(
    Float64[],
    CachedVector(Int),
    CachedVector(Int),
    CachedVector(Vector{Float64}),
    CachedVector(Float64),
    CachedVector(Float64),
    CachedVector(Float64)
)
function reset!(s::Storage)
    reset!(s.noise)
    reset!(s.markov)
    reset!(s.duals)
    reset!(s.objective)
    reset!(s.probability)
    reset!(s.modifiedprobability)
end

struct SolutionLog
    iteration::Int
    bound::Float64
    lower_statistical_bound::Float64
    upper_statistical_bound::Float64
    timecuts::Float64
    simulations::Int
    timesimulations::Float64
    timetotal::Float64
end

struct SDDPModel{V<:AbstractValueFunction}
    sense::Symbol
    stages::Vector{Stage}
    storage::Storage
    log::Vector{SolutionLog}
    build!::Function
    ext::Dict # extension dictionary
end
newSDDPModel(sense::Symbol, v::AbstractValueFunction, build!::Function) = newSDDPModel(sense, typeof(v), build!)
newSDDPModel(sense::Symbol, v::Type{V}, build!::Function) where {V<:AbstractValueFunction} = SDDPModel{V}(sense, Stage[], Storage(), SolutionLog[], build!, Dict())

struct BoundStalling
    iterations::Int
    rtol::Float64
    atol::Float64
end
"""
    BoundStalling(;kwargs...)

# Description

Collection of settings to control the bound stalling convergence test.

# Arguments
* `iterations::Int`
Terminate if the maximum deviation in the deterministic bound from the mean
over the last `iterations` number of iterations is less than `rtol` (in
relative terms) or `atol` (in absolute terms).
* `rtol::Float64`
Maximum allowed relative deviation from the mean.
Defaults to `0.0`
* `atol::Float64`
Maximum allowed absolute deviation from the mean.
Defaults to `0.0`
"""
BoundStalling(;iterations=0,rtol=0.0,atol=0.0) = BoundStalling(iterations,rtol,atol)

struct MonteCarloSimulation
    frequency::Int
    steps::Vector{Int}
    confidence::Float64
    termination::Bool
end
"""
    MonteCarloSimulation(;kwargs...)

# Description

Collection of settings to control the simulation phase of the SDDP solution
process.

# Arguments
* `frequency::Int`
The frequency (by iteration) with which to run the policy simulation phase of
the algorithm in order to construct a statistical bound for the policy. Defaults
to `0` (never run).
* `min::Float64`
Minimum number of simulations to conduct before constructing a confidence interval
for the bound. Defaults to `20`.
* `step::Float64`
Number of additional simulations to conduct before constructing a new confidence
interval for the bound. Defaults to `1`.
* `max::Float64`
Maximum number of simulations to conduct in the policy simulation phase. Defaults
to `min`.
* `confidence::Float64`
Confidence level of the confidence interval. Defaults to `0.95` (95% CI).
* `termination::Bool`
Whether to terminate the solution algorithm with the status `:converged` if the
deterministic bound is with in the statistical bound after `max` simulations.
Defaults to `false`.
"""
function MonteCarloSimulation(;
    frequency   = 0,
    min         = 20,
    max         = 0,
    step        = 1,
    confidence  = 0.95,
    terminate   = false,
    termination = nothing
    )
    if termination != nothing
        warn("The keyword `termination` is deprecated. Use `terminate` instead.")
        terminate = termination
    end
    MonteCarloSimulation(
        frequency,
        collect(min:step:max),
        confidence,
        terminate
    )
end

struct Settings
    iteration_limit::Int
    time_limit::Float64
    simulation::MonteCarloSimulation
    bound_stalling::BoundStalling
    cut_selection_frequency::Int
    print_level::Int
    log_file::String
    reduce_memory_footprint::Bool
    cut_output_file::IOStream
    is_asynchronous::Bool
end
Settings() = Settings(0,600.0, MonteCarloSimulation(), BoundStalling(), 0,0,"", false, IOStream("Cuts"), false)
