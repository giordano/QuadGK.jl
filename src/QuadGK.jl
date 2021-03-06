# This file was formerly a part of Julia. License is MIT: http://julialang.org/license

__precompile__()
module QuadGK

# see PRs #19741 and #22763
if v"0.6.0-dev.1764" ≤ VERSION < v"0.7.0-DEV.986" && isdefined(Base, :quadgk)
    import Base: quadgk
end

if !isdefined(Base, :QuadGK)
    export quadgk, gauss, kronrod
end

using Compat
using DataStructures
import Base: isless, Order.Reverse, AnyDict

# Adaptive Gauss-Kronrod quadrature routines (arbitrary precision),
# written and contributed to Julia by Steven G. Johnson, 2013.

###########################################################################

# cache of (T,n) -> (x,w,gw) Kronrod rules, to avoid recomputing them
# unnecessarily for repeated integration.   We initialize it with the
# default n=7 rule for double-precision calculations.
const rulecache = AnyDict( (Float64,7) => # precomputed in 100-bit arith.
  ([-9.9145537112081263920685469752598e-01,
    -9.4910791234275852452618968404809e-01,
    -8.6486442335976907278971278864098e-01,
    -7.415311855993944398638647732811e-01,
    -5.8608723546769113029414483825842e-01,
    -4.0584515137739716690660641207707e-01,
    -2.0778495500789846760068940377309e-01,
    0.0],
   [2.2935322010529224963732008059913e-02,
    6.3092092629978553290700663189093e-02,
    1.0479001032225018383987632254189e-01,
    1.4065325971552591874518959051021e-01,
    1.6900472663926790282658342659795e-01,
    1.9035057806478540991325640242055e-01,
    2.0443294007529889241416199923466e-01,
    2.0948214108472782801299917489173e-01],
    [1.2948496616886969327061143267787e-01,
     2.797053914892766679014677714229e-01,
     3.8183005050511894495036977548818e-01,
     4.1795918367346938775510204081658e-01]) )

# integration segment (a,b), estimated integral I, and estimated error E
struct Segment
    a::Number
    b::Number
    I
    E
end
isless(i::Segment, j::Segment) = isless(i.E, j.E)


# Internal routine: approximately integrate f(x) over the interval (a,b)
# by evaluating the integration rule (x,w,gw). Return a Segment.
function evalrule(f, a,b, x,w,gw, nrm)
    # Ik and Ig are integrals via Kronrod and Gauss rules, respectively
    s = convert(eltype(x), 0.5) * (b-a)
    n1 = 1 - (length(x) & 1) # 0 if even order, 1 if odd order
    # unroll first iterationof loop to get correct type of Ik and Ig
    fg = f(a + (1+x[2])*s) + f(a + (1-x[2])*s)
    fk = f(a + (1+x[1])*s) + f(a + (1-x[1])*s)
    Ig = fg * gw[1]
    Ik = fg * w[2] + fk * w[1]
    for i = 2:length(gw)-n1
        fg = f(a + (1+x[2i])*s) + f(a + (1-x[2i])*s)
        fk = f(a + (1+x[2i-1])*s) + f(a + (1-x[2i-1])*s)
        Ig += fg * gw[i]
        Ik += fg * w[2i] + fk * w[2i-1]
    end
    if n1 == 0 # even: Gauss rule does not include x == 0
        Ik += f(a + s) * w[end]
    else # odd: don't count x==0 twice in Gauss rule
        f0 = f(a + s)
        Ig += f0 * gw[end]
        Ik += f0 * w[end] +
              (f(a + (1+x[end-1])*s) + f(a + (1-x[end-1])*s)) * w[end-1]
    end
    Ik *= s
    Ig *= s
    E = nrm(Ik - Ig)
    if isnan(E) || isinf(E)
        throw(DomainError())
    end
    return Segment(a, b, Ik, E)
end

rulekey(::Type{BigFloat}, n) = (BigFloat, precision(BigFloat), n)
rulekey(T,n) = (T,n)

# Internal routine: integrate f over the union of the open intervals
# (s[1],s[2]), (s[2],s[3]), ..., (s[end-1],s[end]), using h-adaptive
# integration with the order-n Kronrod rule and weights of type Tw,
# with absolute tolerance abstol and relative tolerance reltol,
# with maxevals an approximate maximum number of f evaluations.
function do_quadgk(f, s, n, ::Type{Tw}, abstol, reltol, maxevals, nrm) where Tw
    if eltype(s) <: Real # check for infinite or semi-infinite intervals
        s1 = s[1]; s2 = s[end]; inf1 = isinf(s1); inf2 = isinf(s2)
        if inf1 || inf2
            if inf1 && inf2 # x = t/(1-t^2) coordinate transformation
                return do_quadgk(t -> begin t2 = t*t; den = 1 / (1 - t2);
                                            f(t*den) * (1+t2)*den*den; end,
                                 map(x -> isinf(x) ? copysign(one(x), x) : 2x / (1+hypot(1,2x)), s),
                                 n, Tw, abstol, reltol, maxevals, nrm)
            end
            s0,si = inf1 ? (s2,s1) : (s1,s2)
            if si < 0 # x = s0 - t/(1-t)
                return do_quadgk(t -> begin den = 1 / (1 - t);
                                            f(s0 - t*den) * den*den; end,
                                 reverse!(map(x -> 1 / (1 + 1 / (s0 - x)), s)),
                                 n, Tw, abstol, reltol, maxevals, nrm)
            else # x = s0 + t/(1-t)
                return do_quadgk(t -> begin den = 1 / (1 - t);
                                            f(s0 + t*den) * den*den; end,
                                 map(x -> 1 / (1 + 1 / (x - s0)), s),
                                 n, Tw, abstol, reltol, maxevals, nrm)
            end
        end
    end

    key = rulekey(Tw,n)
    x,w,gw = haskey(rulecache, key) ? rulecache[key] :
       (rulecache[key] = kronrod(Tw, n))
    segs = Segment[]
    for i in 1:length(s) - 1
        heappush!(segs, evalrule(f, s[i],s[i+1], x,w,gw, nrm), Reverse)
    end
    numevals = (2n+1) * length(segs)
    I = segs[1].I
    E = segs[1].E
    for i in 2:length(segs)
        I += segs[i].I
        E += segs[i].E
    end
    # Pop the biggest-error segment and subdivide (h-adaptation)
    # until convergence is achieved or maxevals is exceeded.
    while E > abstol && E > reltol * nrm(I) && numevals < maxevals
        s = heappop!(segs, Reverse)
        mid = (s.a + s.b) * 0.5
        s1 = evalrule(f, s.a, mid, x,w,gw, nrm)
        s2 = evalrule(f, mid, s.b, x,w,gw, nrm)
        heappush!(segs, s1, Reverse)
        heappush!(segs, s2, Reverse)
        I = (I - s.I) + s1.I + s2.I
        E = (E - s.E) + s1.E + s2.E
        numevals += 4n+2
    end
    # re-sum (paranoia about accumulated roundoff)
    I = segs[1].I
    E = segs[1].E
    for i in 2:length(segs)
        I += segs[i].I
        E += segs[i].E
    end
    return (I, E)
end

# Gauss-Kronrod quadrature of f from a to b to c...

function quadgk(f, a::T,b::T,c::T...;
                abstol=zero(T), reltol=sqrt(eps(T)),
                maxevals=10^7, order=7, norm=vecnorm) where T<:AbstractFloat
    do_quadgk(f, [a, b, c...], order, T, abstol, reltol, maxevals, norm)
end

function quadgk(f, a::Complex{T},
                b::Complex{T},c::Complex{T}...;
                abstol=zero(T), reltol=sqrt(eps(T)),
                maxevals=10^7, order=7, norm=vecnorm) where T<:AbstractFloat
    do_quadgk(f, [a, b, c...], order, T, abstol, reltol, maxevals, norm)
end

"""
    quadgk(f, a,b,c...; reltol=sqrt(eps), abstol=0, maxevals=10^7, order=7, norm=vecnorm)

Numerically integrate the function `f(x)` from `a` to `b`, and optionally over additional
intervals `b` to `c` and so on. Keyword options include a relative error tolerance `reltol`
(defaults to `sqrt(eps)` in the precision of the endpoints), an absolute error tolerance
`abstol` (defaults to 0), a maximum number of function evaluations `maxevals` (defaults to
`10^7`), and the `order` of the integration rule (defaults to 7).

Returns a pair `(I,E)` of the estimated integral `I` and an estimated upper bound on the
absolute error `E`. If `maxevals` is not exceeded then `E <= max(abstol, reltol*norm(I))`
will hold. (Note that it is useful to specify a positive `abstol` in cases where `norm(I)`
may be zero.)

The endpoints `a` et cetera can also be complex (in which case the integral is performed over
straight-line segments in the complex plane). If the endpoints are `BigFloat`, then the
integration will be performed in `BigFloat` precision as well.

!!! note
    It is advisable to increase the integration `order` in rough proportion to the
    precision, for smooth integrands.

More generally, the precision is set by the precision of the integration
endpoints (promoted to floating-point types).

The integrand `f(x)` can return any numeric scalar, vector, or matrix type, or in fact any
type supporting `+`, `-`, multiplication by real values, and a `norm` (i.e., any normed
vector space). Alternatively, a different norm can be specified by passing a `norm`-like
function as the `norm` keyword argument (which defaults to `vecnorm`).

!!! note
    Only one-dimensional integrals are provided by this function. For multi-dimensional
    integration (cubature), there are many different algorithms (often much better than simple
    nested 1d integrals) and the optimal choice tends to be very problem-dependent. See the
    Julia external-package listing for available algorithms for multidimensional integration or
    other specialized tasks (such as integrals of highly oscillatory or singular functions).

The algorithm is an adaptive Gauss-Kronrod integration technique: the integral in each
interval is estimated using a Kronrod rule (`2*order+1` points) and the error is estimated
using an embedded Gauss rule (`order` points). The interval with the largest error is then
subdivided into two intervals and the process is repeated until the desired error tolerance
is achieved.

These quadrature rules work best for smooth functions within each interval, so if your
function has a known discontinuity or other singularity, it is best to subdivide your
interval to put the singularity at an endpoint. For example, if `f` has a discontinuity at
`x=0.7` and you want to integrate from 0 to 1, you should use `quadgk(f, 0,0.7,1)` to
subdivide the interval at the point of discontinuity. The integrand is never evaluated
exactly at the endpoints of the intervals, so it is possible to integrate functions that
diverge at the endpoints as long as the singularity is integrable (for example, a `log(x)`
or `1/sqrt(x)` singularity).

For real-valued endpoints, the starting and/or ending points may be infinite. (A coordinate
transformation is performed internally to map the infinite interval to a finite one.)
"""
# generic version: determine precision from a combination of
# all the integration-segment endpoints
function quadgk(f, a, b, c...; kws...)
    T = promote_type(typeof(float(a)), typeof(b))
    for x in c
        T = promote_type(T, typeof(x))
    end
    cT = map(T, c)
    quadgk(f, convert(T, a), convert(T, b), cT...; kws...)
end

###########################################################################
# Gauss-Kronrod integration-weight computation for arbitrary floating-point
# types and precision, implemented based on the description in:
#
#    Dirk P. Laurie, "Calculation of Gauss-Kronrod quadrature rules,"
#    Mathematics of Computation, vol. 66, no. 219, pp. 1133-1145 (1997).
#
# for the Kronrod rule, and for the Gauss rule from the description in
#
#    Lloyd N. Trefethen and David Bau, Numerical Linear Algebra (SIAM, 1997).
#
# Arbitrary-precision eigenvalue (eignewt & eigpoly) and eigenvector
# (eigvec1) routines are written by SGJ, independent of the above sources.
#
# Since we only implement Gauss-Kronrod rules for the unit weight function,
# the diagonals of the Jacobi matrices are zero and certain things simplify
# compared to the general case of an arbitrary weight function.

# Given a symmetric tridiagonal matrix H with H[i,i] = 0 and
# H[i-1,i] = H[i,i-1] = b[i-1], compute p(z) = det(z I - H) and its
# derivative p'(z), returning (p,p').
function eigpoly(b,z,m=length(b)+1)
    d1 = z
    d1deriv = d2 = one(z)
    d2deriv = zero(z)
    for i = 2:m
        b2 = b[i-1]^2
        d = z * d1 - b2 * d2
        dderiv = d1 + z * d1deriv - b2 * d2deriv
        d2 = d1
        d1 = d
        d2deriv = d1deriv
        d1deriv = dderiv
    end
    return (d1, d1deriv)
end

# compute the n smallest eigenvalues of the symmetric tridiagonal matrix H
# (defined from b as in eigpoly) using a Newton iteration
# on det(H - lambda I).  Unlike eig, handles BigFloat.
function eignewt(b,m,n)
    # get initial guess from eig on Float64 matrix
    H = SymTridiagonal(zeros(m), Float64[ b[i] for i in 1:m-1 ])
    lambda0 = sort(eigvals(H))

    lambda = Array{eltype(b)}(uninitialized, n)
    for i = 1:n
        lambda[i] = lambda0[i]
        for k = 1:1000
            (p,pderiv) = eigpoly(b,lambda[i],m)
            lambda[i] = (lamold = lambda[i]) - p / pderiv
            if abs(lambda[i] - lamold) < 10 * eps(lambda[i]) * abs(lambda[i])
                break
            end
        end
        # do one final Newton iteration for luck and profit:
        (p,pderiv) = eigpoly(b,lambda[i],m)
        lambda[i] = lambda[i] - p / pderiv
    end
    return lambda
end

# given an eigenvalue z and the matrix H(b) from above, return
# the corresponding eigenvector, normalized to 1.
function eigvec1(b,z::Number,m=length(b)+1)
    # "cheat" and use the fact that our eigenvector v must have a
    # nonzero first entries (since it is a quadrature weight), so we
    # can set v[1] = 1 to solve for the rest of the components:.
    v = Array{eltype(b)}(uninitialized, m)
    v[1] = 1
    if m > 1
        s = v[1]
        v[2] = z * v[1] / b[1]
        s += v[2]^2
        for i = 3:m
            v[i] = - (b[i-2]*v[i-2] - z*v[i-1]) / b[i-1]
            s += v[i]^2
        end
        scale!(v, 1 / sqrt(s))
    end
    return v
end

"""
    gauss([T,] N)

Return a pair `(x, w)` of `N` quadrature points `x[i]` and weights `w[i]` to
integrate functions on the interval `(-1, 1)`,  i.e. `sum(w .* f.(x))`
approximates the integral.  Uses the method described in Trefethen &
Bau, Numerical Linear Algebra, to find the `N`-point Gaussian quadrature
in O(`N`²) operations.

`T` is an optional parameter specifying the floating-point type, defaulting
to `Float64`. Arbitrary precision (`BigFloat`) is also supported.
"""
function gauss(::Type{T}, N::Integer) where T<:AbstractFloat
    if N < 1
        throw(ArgumentError("Gauss rules require positive order"))
    end
    o = one(T)
    b = T[ n / sqrt(4n^2 - o) for n = 1:N-1 ]
    x = eignewt(b,N,N)
    w = T[ 2*eigvec1(b,x[i])[1]^2 for i = 1:N ]
    return (x, w)
end

gauss(N::Integer) = gauss(Float64, N)

"""
    kronrod([T,] n)

Compute `2n+1` Kronrod points `x` and weights `w` based on the description in
Laurie (1997), appendix A, simplified for `a=0`, for integrating on `[-1,1]`.
Since the rule is symmetric, this only returns the `n+1` points with `x <= 0`.
The function Also computes the embedded `n`-point Gauss quadrature weights `gw`
(again for `x <= 0`), corresponding to the points `x[2:2:end]`. Returns `(x,w,wg)`
in O(`n`²) operations.

`T` is an optional parameter specifying the floating-point type, defaulting
to `Float64`. Arbitrary precision (`BigFloat`) is also supported.

Given these points and weights, the estimated integral `I` and error `E` can
be computed for an integrand `f(x)` as follows:

    x, w, wg = kronrod(n)
    fx⁰ = f(x[end])                # f(0)
    x⁻ = x[1:end-1]                # the x < 0 Kronrod points
    fx = f.(x⁻) .+ f.((-).(x⁻))    # f(x < 0) + f(x > 0)
    I = sum(fx .* w[1:end-1]) + fx⁰ * w[end]
    if isodd(n)
        E = abs(sum(fx[2:2:end] .* wg[1:end-1]) + fx⁰*wg[end] - I)
    else
        E = abs(sum(fx[2:2:end] .* wg[1:end])- I)
    end
"""
function kronrod(::Type{T}, n::Integer) where T<:AbstractFloat
    if n < 1
        throw(ArgumentError("Kronrod rules require positive order"))
    end
    o = one(T)
    b = zeros(T, 2n+1)
    b[1] = 2*o
    for j = 1:div(3n+1,2)
        b[j+1] = j^2 / (4j^2 - o)
    end
    s = zeros(T, div(n,2) + 2)
    t = zeros(T, div(n,2) + 2)
    t[2] = b[n+2]
    for m = 0:n-2
        u = zero(T)
        for k = div(m+1,2):-1:0
            l = m - k + 1
            k1 = k + n + 2
            u += b[k1]*s[k+1] - b[l]*s[k+2]
            s[k+2] = u
        end
        s,t = t,s
    end
    for j = div(n,2):-1:0
        s[j+2] = s[j+1]
    end
    for m = n-1:2n-3
        u = zero(T)
        for k = m+1-n:div(m-1,2)
            l = m - k + 1
            j = n - l
            k1 = k + n + 2
            u -= b[k1]*s[j+2] - b[l]*s[j+3]
            s[j+2] = u
        end
        k = div(m+1,2)
        if 2k != m
            j = n - (m - k + 2)
            b[k+n+2] = s[j+2] / s[j+3]
        end
        s,t = t,s
    end
    for j = 1:2n
        b[j] = sqrt(b[j+1])
    end

    # get negative quadrature points x
    x = eignewt(b,2n+1,n+1) # x <= 0

    # get quadrature weights
    w = T[ 2*eigvec1(b,x[i],2n+1)[1]^2 for i in 1:n+1 ]

    # Get embedded Gauss rule from even-indexed points, using
    # the method described in Trefethen and Bau.
    for j = 1:n-1
        b[j] = j / sqrt(4j^2 - o)
    end
    gw = T[ 2*eigvec1(b,x[i],n)[1]^2 for i = 2:2:n+1 ]

    return (x, w, gw)
end

kronrod(N::Integer) = kronrod(Float64, N)

###########################################################################

end # module QuadGK
