# Copyright 2016 Martin Holters
# See accompanying license file.

export SimpleSolver, HomotopySolver, CachingSolver

type ParametricNonLinEq{F<:Function}
    func::F
    res::Vector{Float64}
    Jp::Matrix{Float64}
    J::Matrix{Float64}
    function ParametricNonLinEq(func::F, nn::Integer, np::Integer)
        res = zeros(nn)
        Jp = zeros(nn, np)
        J = zeros(nn, nn)
        return new(func, res, Jp, J)
    end
end
ParametricNonLinEq{F<:Function}(func::F, nn::Integer, np::Integer) =
    ParametricNonLinEq{F}(func, nn, np)

nn(nleq::ParametricNonLinEq) = length(nleq.res)
np(nleq::ParametricNonLinEq) = size(nleq.Jp, 2)

evaluate!(nleq::ParametricNonLinEq, p, z) =
    nleq.func(nleq.res, nleq.J, nleq.Jp, p, z)


type SimpleSolver{NLEQ<:ParametricNonLinEq}
    nleq::NLEQ
    z::Vector{Float64}
    JLU::Base.LU{Float64,Matrix{Float64}}
    lu_info::Ref{Base.LinAlg.BlasInt}
    last_z::Vector{Float64}
    last_p::Vector{Float64}
    last_Jp::Matrix{Float64}
    last_JLU::Base.LU{Float64,Matrix{Float64}}
    iters::Int
    ressumabs2::Float64
    tol::Float64
    tmp_nn::Vector{Float64}
    tmp_np::Vector{Float64}
    function SimpleSolver(nleq::NLEQ, initial_p::Vector{Float64},
                          initial_z::Vector{Float64})
        z = zeros(nn(nleq))
        ipiv = zeros(Base.LinAlg.BlasInt, nn(nleq))
        JLU = Base.LU{Float64,Matrix{Float64}}(nleq.J, ipiv, Base.LinAlg.BlasInt(0))
        lu_info = Ref{Base.LinAlg.BlasInt}(0)
        last_z = zeros(nn(nleq))
        last_p = zeros(np(nleq))
        last_Jp = zeros(nn(nleq), np(nleq))
        last_JLU = Base.LU{Float64,Matrix{Float64}}(similar(nleq.J), similar(ipiv),
                                                    Base.LinAlg.BlasInt(0))
        tmp_nn = zeros(nn(nleq))
        tmp_np = zeros(np(nleq))
        solver = new(nleq, z, JLU, lu_info, last_z, last_p, last_Jp, last_JLU,
                     0, 0.0, 1e-20, tmp_nn, tmp_np)
        set_extrapolation_origin(solver, initial_p, initial_z)
        return solver
    end
end
SimpleSolver{NLEQ<:ParametricNonLinEq}(nleq::NLEQ, initial_p::Vector{Float64},
                                       initial_z::Vector{Float64}) =
    SimpleSolver{NLEQ}(nleq, initial_p, initial_z)

set_resabs2tol!(solver::SimpleSolver, tol) = solver.tol = tol

function set_extrapolation_origin(solver::SimpleSolver, p, z)
    evaluate!(solver.nleq, p, z)
    getrf!(solver.JLU, solver.lu_info)
    set_extrapolation_origin(solver, p, z, solver.nleq.Jp, solver.JLU)
end

function set_extrapolation_origin(solver::SimpleSolver, p, z, Jp, JLU)
    copy!(solver.last_JLU.factors, JLU.factors)
    copy!(solver.last_JLU.ipiv, JLU.ipiv)
    copy!(solver.last_Jp, Jp)
    copy!(solver.last_p, p)
    copy!(solver.last_z, z)
end

get_extrapolation_origin(solver::SimpleSolver) = solver.last_p, solver.last_z

hasconverged(solver::SimpleSolver) = solver.ressumabs2 < solver.tol

needediterations(solver::SimpleSolver) = solver.iters

# Note: lu.info is not updated!
function getrf!(lu::Base.LU{Float64,Matrix{Float64}}, info::Ref{Base.LinAlg.BlasInt})
    m, n = size(lu.factors)
    lda  = max(1, m)
    ccall((Compat.@blasfunc(dgetrf_), Base.LinAlg.LAPACK.liblapack), Void,
          (Ptr{Base.LinAlg.BlasInt}, Ptr{Base.LinAlg.BlasInt}, Ptr{Float64},
           Ptr{Base.LinAlg.BlasInt}, Ptr{Base.LinAlg.BlasInt}, Ptr{Base.LinAlg.BlasInt}),
          &m, &n, lu.factors, &lda, lu.ipiv, info)
    return nothing
end

function getrs!(trans::Char, A::Matrix{Float64}, ipiv::Vector{Base.LinAlg.BlasInt}, B::Vector{Float64}, info::Ref{Base.LinAlg.BlasInt})
    Base.LinAlg.LAPACK.chktrans(trans)
    Base.LinAlg.chkstride1(A, B, ipiv)
    n = size(A, 2)
    if n ≠ size(A, 1)
        throw(DimensionMismatch("matrix is not square: dimensions are $(size(A))"))
    end
    if n ≠ size(B, 1)
        throw(DimensionMismatch("B has leading dimension $(size(B,1)), but needs $n"))
    end
    ccall((Compat.@blasfunc(dgetrs_), Base.LinAlg.LAPACK.liblapack), Void,
          (Ptr{UInt8}, Ptr{Base.LinAlg.BlasInt}, Ptr{Base.LinAlg.BlasInt}, Ptr{Float64}, Ptr{Base.LinAlg.BlasInt},
           Ptr{Base.LinAlg.BlasInt}, Ptr{Float64}, Ptr{Base.LinAlg.BlasInt}, Ptr{Base.LinAlg.BlasInt}),
          &trans, &n, &1, A, &max(1,stride(A,2)), ipiv, B, &max(1,stride(B,2)), info)
    if info[] ≠ 0
        throw(LAPACKException(info[]))
    end
    B
end


function solve(solver::SimpleSolver, p::AbstractVector{Float64}, maxiter=500)
    #solver.z = solver.last_z - solver.last_JLU\(solver.last_Jp * (p-solver.last_p))
    copy!(solver.tmp_np, p)
    BLAS.axpy!(-1.0, solver.last_p, solver.tmp_np)
    BLAS.gemv!('N', 1.,solver.last_Jp, solver.tmp_np, 0., solver.tmp_nn)
    getrs!('N', solver.last_JLU.factors, solver.last_JLU.ipiv, solver.tmp_nn, solver.lu_info)
    copy!(solver.z, solver.last_z)
    BLAS.axpy!(-1.0, solver.tmp_nn, solver.z)

    for solver.iters=1:maxiter
        evaluate!(solver.nleq, p, solver.z)
        solver.ressumabs2 = sumabs2(solver.nleq.res)
        if ~isfinite(solver.ressumabs2) || ~all(isfinite, solver.nleq.J)
            return solver.z
        end
        getrf!(solver.JLU, solver.lu_info)
        if solver.lu_info[] > 0 # J was singular
            return solver.z
        end
        hasconverged(solver) && break
        #solver.z -= solver.JLU\solver.nleq.res
        copy!(solver.tmp_nn, solver.nleq.res)
        getrs!('N', solver.JLU.factors, solver.JLU.ipiv, solver.tmp_nn, solver.lu_info)
        BLAS.axpy!(-1.0, solver.tmp_nn, solver.z)
    end
    if hasconverged(solver)
        set_extrapolation_origin(solver, p, solver.z, solver.nleq.Jp, solver.JLU)
    end
    return solver.z
end


type HomotopySolver{BaseSolver}
    basesolver::BaseSolver
    start_p::Vector{Float64}
    iters::Int
    function HomotopySolver(basesolver::BaseSolver, np::Integer)
        return new(basesolver, zeros(np), 0)
    end
    function HomotopySolver(nleq::ParametricNonLinEq,
                            initial_p::Vector{Float64},
                            initial_z::Vector{Float64})
        basesolver = BaseSolver(nleq, initial_p, initial_z)
        return HomotopySolver{typeof(basesolver)}(basesolver, np(nleq))
    end
end

set_resabs2tol!(solver::HomotopySolver, tol) =
    set_resabs2tol!(solver.basesolver, tol)

set_extrapolation_origin(solver::HomotopySolver, p, z) =
    set_extrapolation_origin(solver.basesolver, p, z)

function solve(solver::HomotopySolver, p)
    z = solve(solver.basesolver, p)
    solver.iters = needediterations(solver.basesolver)
    if ~hasconverged(solver)
        a = 0.5
        best_a = 0.0
        copy!(solver.start_p, get_extrapolation_origin(solver.basesolver)[1])
        while best_a < 1
            pa = (1-a) * solver.start_p + a * p
            z = solve(solver.basesolver, pa)
            if hasconverged(solver)
                best_a = a
                a = 1.0
            else
                new_a = (a + best_a) / 2
                if !(best_a < new_a < a)
                    # no floating point value inbetween best_a and a
                    break
                end
                a = new_a
            end
        end
    end
    return z
end

hasconverged(solver::HomotopySolver) = hasconverged(solver.basesolver)
needediterations(solver::HomotopySolver) = solver.iters


type CachingSolver{BaseSolver}
    basesolver::BaseSolver
    ps_tree::KDTree{Vector{Float64}, Matrix{Float64}}
    zs::Matrix{Float64}
    num_ps::Int
    new_count::Int
    new_count_limit::Int
    function CachingSolver(basesolver::BaseSolver, initial_p::Vector{Float64},
                           initial_z::Vector{Float64}, nn::Integer)
         ps_tree = KDTree(hcat(initial_p))
         zs = reshape(copy(initial_z), nn, 1)
         return new(basesolver, ps_tree, zs, 1, 0, 2)
    end
    function CachingSolver(nleq::ParametricNonLinEq, initial_p::Vector{Float64},
                          initial_z::Vector{Float64})
        basesolver = BaseSolver(nleq, initial_p, initial_z)
        return CachingSolver{typeof(basesolver)}(basesolver, initial_p, initial_z, nn(nleq))
    end
end

set_resabs2tol!(solver::CachingSolver, tol) =
    set_resabs2tol!(solver.basesolver, tol)

hasconverged(solver::CachingSolver) = hasconverged(solver.basesolver)
needediterations(solver::CachingSolver) = needediterations(solver.basesolver)

function solve(solver::CachingSolver, p)
    best_diff = sumabs2(p - get_extrapolation_origin(solver.basesolver)[1])
    idx = 0
    for i in (solver.num_ps-solver.new_count+1):solver.num_ps
        diff = 0.
        for j in 1:size(solver.ps_tree.ps, 1)
            diff += abs2(solver.ps_tree.ps[j,i] - p[j])
        end
        if diff < best_diff
            best_diff = diff
            idx = i
        end
    end

    idx = indnearest(solver.ps_tree, p,
                     Alts([AltEntry(1, zeros(p), 0.0)], best_diff, idx))[1]

    if idx ≠ 0
        set_extrapolation_origin(solver.basesolver,
                                 solver.ps_tree.ps[:,idx], solver.zs[:,idx])
    end

    z = solve(solver.basesolver, p)
    if needediterations(solver.basesolver) > 5 && hasconverged(solver.basesolver)
        solver.num_ps += 1
        if solver.num_ps > size(solver.ps_tree.ps, 2)
            solver.ps_tree.ps =
                copy!(zeros(size(solver.ps_tree.ps, 1), 2solver.num_ps),
                      solver.ps_tree.ps)
            solver.zs =
                copy!(zeros(size(solver.zs, 1), 2solver.num_ps), solver.zs)
        end
        solver.ps_tree.ps[:,solver.num_ps] = p
        solver.zs[:,solver.num_ps] = z
        solver.new_count += 1
    end
    if solver.new_count > 0
        solver.new_count_limit -= 1
    end
    if solver.new_count > solver.new_count_limit
        solver.ps_tree = KDTree(solver.ps_tree.ps, solver.num_ps)
        solver.new_count = 0
        solver.new_count_limit = 2size(solver.ps_tree.ps, 2)
    end
    return z
end

get_extrapolation_origin(solver::CachingSolver) =
    get_extrapolation_origin(solver.basesolver)
