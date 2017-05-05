doc"""
    PG(n_particles::Int, n_iters::Int)

Particle Gibbs sampler.

Usage:

```julia
PG(100, 100)
```

Example:

```julia
# Define a simple Normal model with unknown mean and variance.
@model gdemo(x) = begin
  s ~ InverseGamma(2,3)
  m ~ Normal(0,sqrt(s))
  x[1] ~ Normal(m, sqrt(s))
  x[2] ~ Normal(m, sqrt(s))
  return s, m
end

sample(gdemo([1.5, 2]), PG(100, 100))
```
"""
immutable PG <: InferenceAlgorithm
  n_particles           ::    Int         # number of particles used
  n_iters               ::    Int         # number of iterations
  resampler             ::    Function    # function to resample
  resampler_threshold   ::    Float64     # threshold of ESS for resampling
  space                 ::    Set         # sampling space, emtpy means all
  gid                   ::    Int         # group ID
  PG(n1::Int, n2::Int) = new(n1, n2, resampleSystematic, 0.5, Set(), 0)
  function PG(n1::Int, n2::Int, space...)
    space = isa(space, Symbol) ? Set([space]) : Set(space)
    new(n1, n2, resampleSystematic, 0.5, space, 0)
  end
  PG(alg::PG, new_gid::Int) = new(alg.n_particles, alg.n_iters, alg.resampler, alg.resampler_threshold, alg.space, new_gid)
end

Sampler(alg::PG) = begin
  info = Dict{Symbol, Any}()
  info[:logevidence] = []
  Sampler(alg, info)
end

function step(model::Function, spl::Sampler{PG}, vi::VarInfo, ref_particle)
  particles = ParticleContainer{TraceR}(model)
  if ref_particle == nothing
    push!(particles, spl.alg.n_particles, spl, vi)
  else
    push!(particles, spl.alg.n_particles-1, spl, vi)
    push!(particles, ref_particle)
  end

  while consume(particles) != Val{:done}
    ess = effectiveSampleSize(particles)
    if ess <= spl.alg.resampler_threshold * length(particles)
      resample!(particles, spl.alg.resampler, ref_particle)
    end
  end

  ## pick a particle to be retained.
  Ws, _ = weights(particles)
  indx = rand(Categorical(Ws))
  ref_particle = fork2(particles[indx])
  push!(spl.info[:logevidence], particles.logE)
  ref_particle
end

sample(model::Function, alg::PG) = begin
  spl = Sampler(alg);
  n = spl.alg.n_iters
  samples = Vector{Sample}()

  ## custom resampling function for pgibbs
  ## re-inserts reteined particle after each resampling step
  ref_particle = nothing
  @showprogress 1 "[PG] Sampling..." for i = 1:n
    ref_particle = step(model, spl, VarInfo(), ref_particle)
    push!(samples, Sample(ref_particle.vi))
  end

  chain = Chain(exp(mean(spl.info[:logevidence])), samples)
end

assume{T<:Union{PG,SMC}}(spl::Sampler{T}, dist::Distribution, vn::VarName, _::VarInfo) = begin
  vi = current_trace().vi
  if isempty(spl.alg.space) || vn.sym in spl.alg.space
    vi.index += 1
    if ~haskey(vi, vn)
      r = rand(dist)
      push!(vi, vn, r, dist, spl.alg.gid)
      spl.info[:cache_updated] = 0b00   # sanity flag mask for getidcs and getranges
      r
    elseif isnan(vi, vn)
      r = rand(dist)
      setval!(vi, vectorize(dist, r), vn)
      r
    else
      checkindex(vn, vi, spl)
      updategid!(vi, vn, spl)
      vi[vn]
    end
  else
    vi[vn]
  end
end

observe{T<:Union{PG,SMC}}(spl::Sampler{T}, dist::Distribution, value, vi) = begin
  lp = logpdf(dist, value)
  vi.logp += lp
  produce(lp)
end
