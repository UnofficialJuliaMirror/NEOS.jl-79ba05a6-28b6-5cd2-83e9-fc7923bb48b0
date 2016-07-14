const NOTSOLVED = :NotSolved
const SOVLERERROR = :SolverError
const OPTIMAL = :Optimal
const UNBOUNDED = :Unbounded
const INFEASIBLE = :Infeasible
const UNBNDORINF = :UnboundedOrInfeasible

abstract AbstractNEOSSolver
type NEOSSolverError <: Exception
	msg::ASCIIString
end

type SOS
	order::Int
	indices::Vector{Int}
	weights::Vector{Float64}
end

type NEOSSolver{T<:AbstractNEOSSolver} <: AbstractMathProgSolver
	server::NEOSServer
	requires_email::Bool
	solves_sos::Bool
	provides_duals::Bool
	template::ASCIIString
	params::Dict{ASCIIString,Any}
	gzipmodel::Bool
	print_results::Bool
	result_file::ASCIIString
end

function NEOSSolver{T<:AbstractNEOSSolver}(solver::Type{T}, requireemail::Bool, solvesos::Bool, provideduals::Bool, template::ASCIIString, server::NEOSServer, email::ASCIIString,  gzipmodel::Bool, print_results::Bool, result_file::ASCIIString, kwargs...)
	if email != ""
		addemail!(server, email)
	end
	params=Dict{ASCIIString,Any}()
	for (key, value) in kwargs
		params[string(key)] = value
	end
	NEOSSolver{solver}(server, requireemail, solvesos, provideduals, template, params, gzipmodel, print_results, result_file)
end

# sense: c'x
# s/t.   rowlb <= Ax <= rowub
#        collb <=  x <= colub
type NEOSMathProgModel <: AbstractMathProgModel
	solver::NEOSSolver
	xmlmodel::ASCIIString
	last_results::ASCIIString

	ncol::Int64
	nrow::Int64
	A::AbstractArray
	collb::Vector{Float64}
	colub::Vector{Float64}
	f::Vector{Float64}
	rowlb::Vector{Float64}
	rowub::Vector{Float64}
	sense::Symbol
	colcat::Vector{Symbol}
	sos::Vector{SOS}
	objVal::Float64
	reducedcosts::Vector{Float64}
	duals::Vector{Float64}
	solution::Vector{Float64}
	status::Symbol

	NEOSMathProgModel(solver) = new(solver, "", "", 0, 0, Array(Float64, (0,0)), Float64[], Float64[], Float64[], Float64[], Float64[], :Min, Float64[], SOS[], 0., Float64[], Float64[], Float64[], NOTSOLVED)
end

LinearQuadraticModel{T<:AbstractNEOSSolver}(s::NEOSSolver{T}) = NEOSMathProgModel(s)

function addparameter!{T<:AbstractNEOSSolver}(s::NEOSSolver{T}, param::ASCIIString, value)
	s.params[param] = value
end

addemail!(m::NEOSMathProgModel, email::ASCIIString) = addemail!(m.solver.server, email)
addemail!{T<:AbstractNEOSSolver}(s::NEOSSolver{T}, email::ASCIIString) = addemail!(s.server, email)

function loadproblem!(m::NEOSMathProgModel, A, collb, colub, f, rowlb, rowub, sense)
	@assert length(collb) == length(colub) == length(f) == size(A)[2]
	@assert length(rowlb) == length(rowub) == size(A)[1]
	m.ncol = length(f)
	m.nrow = length(rowlb)
	m.A = A
	m.collb = collb
	m.colub = colub
	m.colcat = fill(:Cont, m.ncol)
	m.f = f
	m.rowlb = rowlb
	m.rowub = rowub
	m.sense = sense
end

function build_mps(m::NEOSMathProgModel)
    io = IOBuffer()
    sos = MPSWriter.SOS[]
    for s in m.sos
        push!(sos, MPSWriter.SOS(s.order, s.indices, s.weights))
    end
    writemps(io,
        m.A,
        m.collb,
        m.colub,
        m.f,
        m.rowlb,
        m.rowub,
        m.sense,
        m.colcat,
        sos,
        Array(Int, (0,0)),
        "NEOS_jl"
    )
    if m.solver.gzipmodel
        mpsfile = "<base64>"*bytestring(encode(Base64, Libz.deflate(takebuf_array(io))))*"</base64>"
    else
        mpsfile = takebuf_string(io)
    end
    close(io)
    return mpsfile
end

function optimize!(m::NEOSMathProgModel)
	# Convert the model to MPS and add
	m.xmlmodel = replace(m.solver.template, r"<MPS>.*</MPS>"is, "<MPS>" * build_mps(m) * "</MPS>")

	add_solver_xml!(m.solver, m)

	if m.solver.requires_email && m.solver.server.email==""
		throw(NEOSSolverError("$(typeof(m.solver)) requires that NEOS users supply a valid email"))
	end

	if m.solver.server.email != ""
		if match(r"<email>.*</email>", m.xmlmodel) == nothing
			m.xmlmodel = replace(m.xmlmodel, r"<document>", "<document>\n<email>$(m.solver.server.email)</email>")
		else
			m.xmlmodel = replace(m.xmlmodel, r"<email>.*</email>", "<email>$(m.solver.server.email)</email>")
		end
	end

	job = submitJob(m.solver.server, m.xmlmodel)

	# println("Waiting for results")
	m.last_results = getFinalResults(m.solver.server, job)

	m.solver.print_results && println(m.last_results)
	if m.solver.result_file != ""
		open(m.solver.result_file, "w") do f
			write(f, m.last_results)
		end
	end

	parseresults!(m)

	m.status
end

function anyints(m::NEOSMathProgModel)
	for i in m.colcat
		if i == :Int || i==:Bin
			return true
		end
	end
	return false
end

function parseresults!(m::NEOSMathProgModel)
	m.status = SOVLERERROR
	parse_status!(m.solver, m)
	if m.status == OPTIMAL
		parse_objective!(m.solver, m)
		m.solution = zeros(m.ncol)
		parse_solution!(m.solver, m)
		if m.solver.provides_duals && length(m.sos) == 0 && !anyints(m)
			parse_duals!(m.solver, m)
		end
		if m.sense == :Max
			# Since MPS does not support Maximisation
			m.objVal = -m.objVal
		end
	end
end

function addsos1!(m::NEOSMathProgModel, indices::Vector, weights::Vector)
	if !m.solver.solves_sos
		throw(NEOSSolverError("Special Ordered Sets of type I are not supported by $(typeof(m.solver)). Try a different solver instead"))
	end
	push!(m.sos, SOS(1, indices, weights))
end
function addsos2!(m::NEOSMathProgModel, indices::Vector, weights::Vector)
	if !m.solver.solves_sos
		throw(NEOSSolverError("Special Ordered Sets of type II are not supported by $(typeof(m.solver)). Try a different solver instead"))
	end
	push!(m.sos, SOS(2, indices, weights))
end

function status(m::NEOSMathProgModel)
	m.status
end

function getobjval(m::NEOSMathProgModel)
	m.objVal
end

function getsolution(m::NEOSMathProgModel)
	m.solution
end

function getreducedcosts(m::NEOSMathProgModel)
	if m.solver.provides_duals
		return m.reducedcosts
	else
		warn("Reduced costs are not available from $(typeof(m.solver)). Try a different solver instead")
		return fill(NaN, m.ncol)
	end
end

function getconstrduals(m::NEOSMathProgModel)
	if m.solver.provides_duals
		return 	m.duals
	else
		warn("Constraint duals are not available from $(typeof(m.solver)). Try a different solver instead")
		return fill(NaN, m.nrow)
	end
end

function getsense(m::NEOSMathProgModel)
	m.sense
end

function setsense!(m::NEOSMathProgModel, sense::Symbol)
	m.sense = sense
end

function setvartype!(m::NEOSMathProgModel, t::Vector{Symbol})
	m.colcat = t
end
