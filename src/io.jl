##### Array{T} #####

struct MMSer{T} end # sentinal type used in deserialize to switch to our
                    # custom memory-mapping deserializers

can_mmap(io::IOStream) = true
can_mmap(io::IO) = false

function deserialize{T}(s::AbstractSerializer, ::Type{MMSer{T}})
    mmread(T, s, can_mmap(s.io))
end

mmwrite(io::IO, xs) = mmwrite(SerializationState(io), xs)
mmwrite(io::AbstractSerializer, xs) = serialize(io, xs) # fallback

function mmwrite(io::AbstractSerializer, arr::A) where A<:Union{Array,BitArray}
    T = eltype(A)
    Base.serialize_type(io, MMSer{typeof(arr)})
    if isbits(T)
        serialize(io, size(arr))
        write(io.io, arr)
        return
    elseif T<:Union{} || T<:Nullable{Union{}}
        serialize(io, size(arr))
        return
    end

    fl = fixedlength(T)
    if fl > 0
        serialize(io, size(arr))
        for x in arr
            fast_write(io.io, x)
        end
    else
        serialize(io, arr)
    end
end

function mmread(::Type{A}, io, mmap) where A<:Union{Array,BitArray}
    T = eltype(A)
    if isbits(T)
        sz = deserialize(io)
        if prod(sz) == 0
            return A(sz...)
        end
        if mmap
            data = Mmap.mmap(io.io, A, sz, position(io.io))
            seek(io.io, position(io.io)+sizeof(data)) # move
            return data
        else
            return Base.read!(io.io, A(sz...))
        end
    elseif T<:Union{} || T<:Nullable{Union{}}
        sz = deserialize(io)
        return Array{T}(sz)
    end

    fl = fixedlength(T)
    if fl > 0
        sz = deserialize(io)
        arr = A(sz...)
        @inbounds for i in eachindex(arr)
            arr[i] = fast_read(io.io, T)::T
        end
        return arr
    else
        return deserialize(io) # slow!!
    end
end

##### Array{String} #####

function mmwrite(io::AbstractSerializer, xs::Array{String})
    Base.serialize_type(io, MMSer{typeof(xs)})

    lengths = map(x->convert(UInt32, endof(x)), xs)
    buffer = Vector{UInt8}(sum(lengths))
    serialize(io, size(xs))
    # todo: write directly to buffer, but also mmap
    ptr = pointer(buffer)
    for x in xs
        l = endof(x)
        unsafe_copy!(ptr, pointer(x), l)
        ptr += l
    end

    mmwrite(io, buffer)
    mmwrite(io, lengths)
end

function mmread{N}(::Type{Array{String,N}}, io, mmap)
    sz = deserialize(io)
    buf = deserialize(io)
    lengths = deserialize(io)

    @assert length(buf) == sum(lengths)
    @assert prod(sz) == length(lengths)

    ys = Array{String,N}(sz...) # output
    ptr = pointer(buf)
    @inbounds for i = 1:length(ys)
        l = lengths[i]
        ys[i] = unsafe_string(ptr, l)
        ptr += l
    end
    ys
end


## Optimized fixed length IO
## E.g. this is very good for `StaticArrays.MVector`s

function fixedlength(t::Type, cycles=ObjectIdDict())
    if isbits(t)
        return sizeof(t)
    elseif isa(t, UnionAll)
        return -1
    end

    if haskey(cycles, t)
        return -1
    end
    cycles[t] = nothing
    lens = ntuple(i->fixedlength(fieldtype(t, i), copy(cycles)), nfields(t))
    if isempty(lens)
        # e.g. abstract type / array type
        return -1
    elseif any(x->x<0, lens)
        return -1
    else
        return sum(lens)
    end
end

fixedlength(t::Type{<:String}, cycles=nothing) = -1
fixedlength(t::Type{<:Ptr}, cycles=nothing) = -1

function gen_writer{T}(::Type{T}, expr)
    @assert fixedlength(T) >= 0 "gen_writer must be called for fixed length eltypes"
    if T<:Tuple
        :(write(io, Ref{$T}($expr)))
    elseif length(T.types) > 0
        :(begin
              $([gen_writer(fieldtype(T, i), :(getfield($expr, $i))) for i=1:nfields(T)]...)
          end)
    elseif isbits(T)
        return :(write(io, $expr))
    else
        error("Don't know how to serialize $T")
    end
end

function gen_reader{T}(::Type{T})
    @assert fixedlength(T) >= 0 "gen_reader must be called for fixed length eltypes"
    if T<:Tuple
        :(read(io, Ref{$T}())[])
    elseif length(T.types) > 0
        return :(ccall(:jl_new_struct, Any, (Any,Any...), $T, $([gen_reader(fieldtype(T, i)) for i=1:nfields(T)]...)))
    elseif isbits(T)
        return :(read(io, $T))
    else
        error("Don't know how to deserialize $T")
    end
end

@generated function fast_write(io, x)
    gen_writer(x, :x)
end

@generated function fast_read{T}(io, ::Type{T})
    gen_reader(T)
end