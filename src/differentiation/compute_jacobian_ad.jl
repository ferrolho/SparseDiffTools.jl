struct ForwardColorJacCache{T,T2,T3,T4,T5,T6}
    t::T
    fx::T2
    dx::T3
    p::T4
    colorvec::T5
    sparsity::T6
    chunksize::Int
end

getsize(::Val{N}) where N = N
getsize(N::Integer) = N
void_setindex!(args...) = (setindex!(args...); return)

const default_chunk_size = ForwardDiff.pickchunksize

function ForwardColorJacCache(f::F,x,_chunksize = nothing;
                              dx = nothing,
                              colorvec=1:length(x),
                              sparsity::Union{AbstractArray,Nothing}=nothing) where {F}

    if _chunksize isa Nothing
        chunksize = ForwardDiff.pickchunksize(maximum(colorvec))
    else
        chunksize = _chunksize
    end

    if x isa Array
        p = generate_chunked_partials(x,colorvec,chunksize)
        t = similar(x,Dual{typeof(ForwardDiff.Tag(f,eltype(vec(x)))),eltype(x),length(first(first(p)))})
        for i in eachindex(t)
            t[i] = Dual{typeof(ForwardDiff.Tag(f,eltype(vec(x)))),eltype(x),length(first(first(p)))}(x[i],ForwardDiff.Partials(first(p)[i]))
        end
    else
        p = adapt.(parameterless_type(x),generate_chunked_partials(x,colorvec,chunksize))
        _t = Dual{typeof(ForwardDiff.Tag(f,eltype(vec(x))))}.(vec(x),first(p))
        t = ArrayInterface.restructure(x,_t)
    end


    if dx isa Nothing
        fx = similar(t)
        _dx = similar(x)
    else
        tup = ArrayInterface.allowed_getindex(ArrayInterface.allowed_getindex(p,1),1) .* false
        _pi = adapt(parameterless_type(dx),[tup for i in 1:length(dx)])
        fx = reshape(Dual{typeof(ForwardDiff.Tag(f,eltype(vec(x))))}.(vec(dx),_pi),size(dx)...)
        _dx = dx
    end

    ForwardColorJacCache(t,fx,_dx,p,colorvec,sparsity,getsize(chunksize))
end

generate_chunked_partials(x,colorvec,N::Integer) = generate_chunked_partials(x,colorvec,Val(N))
function generate_chunked_partials(x,colorvec,::Val{chunksize}) where chunksize
    maxcolor = maximum(colorvec)
    num_of_chunks = Int(ceil(maxcolor / chunksize))
    padding_size = (chunksize - (maxcolor % chunksize)) % chunksize

    # partials = colorvec .== (1:maxcolor)'
    partials = BitMatrix(undef, length(colorvec), maxcolor)
    for i in 1:maxcolor, j in 1:length(colorvec)
        partials[j,i] = colorvec[j] == i
    end

    padding_matrix = BitMatrix(undef, length(x), padding_size)
    partials = hcat(partials, padding_matrix)


    #chunked_partials = map(i -> Tuple.(eachrow(partials[:,(i-1)*chunksize+1:i*chunksize])),1:num_of_chunks)
    chunked_partials = Vector{Vector{NTuple{chunksize,eltype(x)}}}(undef, num_of_chunks)
    for i in 1:num_of_chunks
        tmp = Vector{NTuple{chunksize,eltype(x)}}(undef, size(partials,1))
        for j in 1:size(partials,1)
            tmp[j] = Tuple(@view partials[j,(i-1)*chunksize+1:i*chunksize])
        end
        chunked_partials[i] = tmp
    end
    chunked_partials
end

@inline function forwarddiff_color_jacobian(f,
                x::AbstractArray{<:Number};
                colorvec = 1:length(x),
                sparsity = nothing,
                jac_prototype = nothing,
                chunksize = nothing,
                dx = sparsity === nothing && jac_prototype === nothing ? nothing : copy(x)) #if dx is nothing, we will estimate dx at the cost of a function call

    if sparsity === nothing && jac_prototype === nothing
        cfg = if chunksize === nothing
            if typeof(x) <: StaticArrays.StaticArray
                ForwardDiff.JacobianConfig(f, x, ForwardDiff.Chunk{StaticArrays.Size(vec(x))[1]}())
            else
                ForwardDiff.JacobianConfig(f, x)
            end
        else
            ForwardDiff.JacobianConfig(f, x, ForwardDiff.Chunk(getsize(chunksize)))
        end
        return ForwardDiff.jacobian(f, x, cfg)
    end
    if dx isa Nothing
        dx = f(x)
    end
    return forwarddiff_color_jacobian(f,x,ForwardColorJacCache(f,x,chunksize,dx=dx,colorvec=colorvec,sparsity=sparsity),jac_prototype)
end

@inline function forwarddiff_color_jacobian(J::AbstractArray{<:Number}, f,
                x::AbstractArray{<:Number};
                colorvec = 1:length(x),
                sparsity = nothing,
                jac_prototype = nothing,
                chunksize = nothing,
                dx = similar(x, size(J, 1))) #dx kwarg can be used to avoid re-allocating dx every time
    if sparsity === nothing && jac_prototype === nothing
        cfg = chunksize === nothing ? ForwardDiff.JacobianConfig(f, x) : ForwardDiff.JacobianConfig(f, x, ForwardDiff.Chunk(getsize(chunksize)))
        return ForwardDiff.jacobian(f, x, cfg)
    end
    return forwarddiff_color_jacobian(J,f,x,ForwardColorJacCache(f,x,chunksize,dx=dx,colorvec=colorvec,sparsity=sparsity))
end

function forwarddiff_color_jacobian(f,x::AbstractArray{<:Number},jac_cache::ForwardColorJacCache,jac_prototype=nothing)

    if jac_prototype isa Nothing ? ArrayInterface.ismutable(x) : ArrayInterface.ismutable(jac_prototype)
        # Whenever J is mutable, we mutate it to avoid allocations
        dx = jac_cache.dx
        vecx = vec(x)
        sparsity = jac_cache.sparsity

        J = jac_prototype isa Nothing ? (sparsity isa Nothing ? false .* vec(dx) .* vecx' :
                                         zeros(eltype(x),size(sparsity))) : zero(jac_prototype)
        return forwarddiff_color_jacobian(J, f, x, jac_cache)
    else
        return forwarddiff_color_jacobian_immutable(f, x, jac_cache, jac_prototype)
    end
end

# When J is mutable, this version of forwarddiff_color_jacobian will mutate J to avoid allocations
function forwarddiff_color_jacobian(J::AbstractMatrix{<:Number},f,x::AbstractArray{<:Number},jac_cache::ForwardColorJacCache)
    t = jac_cache.t
    dx = jac_cache.dx
    p = jac_cache.p
    colorvec = jac_cache.colorvec
    sparsity = jac_cache.sparsity
    chunksize = jac_cache.chunksize
    color_i = 1
    maxcolor = maximum(colorvec)

    vecx = vec(x)

    nrows,ncols = size(J)

    if !(sparsity isa Nothing)
        rows_index, cols_index = ArrayInterface.findstructralnz(sparsity)
        rows_index = [rows_index[i] for i in 1:length(rows_index)]
        cols_index = [cols_index[i] for i in 1:length(cols_index)]
    end

    for i in eachindex(p)
        partial_i = p[i]
        t = reshape(Dual{typeof(ForwardDiff.Tag(f,eltype(vecx)))}.(vecx, partial_i),size(t))
        fx = f(t)
        if !(sparsity isa Nothing)
            for j in 1:chunksize
                dx = vec(partials.(fx, j))
                pick_inds = [i for i in 1:length(rows_index) if colorvec[cols_index[i]] == color_i]
                rows_index_c = rows_index[pick_inds]
                cols_index_c = cols_index[pick_inds]
                if J isa SparseMatrixCSC || j > 1
                    # Use sparse matrix to add to J column by column except . . .
                    Ji = sparse(rows_index_c, cols_index_c, dx[rows_index_c],nrows,ncols)
                else
                    # To overwrite pre-allocated matrix J, using sparse will cause an error
                    # so we use this step to overwrite J
                    len_rows = length(pick_inds)
                    unused_rows = setdiff(1:nrows,rows_index_c)
                    perm_rows = sortperm(vcat(rows_index_c,unused_rows))
                    cols_index_c = vcat(cols_index_c,zeros(Int,nrows-len_rows))[perm_rows]
                    Ji = [j==cols_index_c[i] ? dx[i] : false for i in 1:nrows, j in 1:ncols]
                end
                if j == 1 && i == 1
                    J .= Ji # overwrite pre-allocated matrix J
                else
                    J .+= Ji
                end
                color_i += 1
                (color_i > maxcolor) && return J
            end
        else
            for j in 1:chunksize
                col_index = (i-1)*chunksize + j
                (col_index > ncols) && return J
                Ji = mapreduce(i -> i==col_index ? partials.(vec(fx), j) : adapt(parameterless_type(J),zeros(eltype(J),nrows)), hcat, 1:ncols)
                if j == 1 && i == 1
                    J .= (size(Ji)!=size(J) ? reshape(Ji,size(J)) : Ji) # overwrite pre-allocated matrix
                else
                    J .+= (size(Ji)!=size(J) ? reshape(Ji,size(J)) : Ji) #branch when size(dx) == (1,) => size(Ji) == (1,) while size(J) == (1,1)
                end
            end
        end
    end
    return J
end

# When J is immutable, this version of forwarddiff_color_jacobian will avoid mutating J
function forwarddiff_color_jacobian_immutable(f,x::AbstractArray{<:Number},jac_cache::ForwardColorJacCache,jac_prototype=nothing)
    t = jac_cache.t
    dx = jac_cache.dx
    p = jac_cache.p
    colorvec = jac_cache.colorvec
    sparsity = jac_cache.sparsity
    chunksize = jac_cache.chunksize
    color_i = 1
    maxcolor = maximum(colorvec)

    vecx = vec(x)

    J = jac_prototype isa Nothing ? (sparsity isa Nothing ? false .* vec(dx) .* vecx' : zeros(eltype(x),size(sparsity))) : zero(jac_prototype)
    nrows,ncols = size(J)

    if !(sparsity isa Nothing)
        rows_index, cols_index = ArrayInterface.findstructralnz(sparsity)
        rows_index = [rows_index[i] for i in 1:length(rows_index)]
        cols_index = [cols_index[i] for i in 1:length(cols_index)]
    end

    for i in eachindex(p)
        partial_i = p[i]
        t = reshape(Dual{typeof(ForwardDiff.Tag(f,eltype(vecx)))}.(vecx, partial_i),size(t))
        fx = f(t)
        if !(sparsity isa Nothing)
            for j in 1:chunksize
                dx = vec(partials.(fx, j))
                pick_inds = [i for i in 1:length(rows_index) if colorvec[cols_index[i]] == color_i]
                rows_index_c = rows_index[pick_inds]
                cols_index_c = cols_index[pick_inds]
                if J isa SparseMatrixCSC
                    Ji = sparse(rows_index_c, cols_index_c, dx[rows_index_c],nrows,ncols)
                else
                    len_rows = length(pick_inds)
                    unused_rows = setdiff(1:nrows,rows_index_c)
                    perm_rows = sortperm(vcat(rows_index_c,unused_rows))
                    cols_index_c = vcat(cols_index_c,zeros(Int,nrows-len_rows))[perm_rows]
                    Ji = [j==cols_index_c[i] ? dx[i] : false for i in 1:nrows, j in 1:ncols]
                end
                J = J + Ji
                color_i += 1
                (color_i > maxcolor) && return J
            end
        else
            for j in 1:chunksize
                col_index = (i-1)*chunksize + j
                (col_index > ncols) && return J
                Ji = mapreduce(i -> i==col_index ? partials.(vec(fx), j) : adapt(parameterless_type(J),zeros(eltype(J),nrows)), hcat, 1:ncols)
                J = J + (size(Ji)!=size(J) ? reshape(Ji,size(J)) : Ji) #branch when size(dx) == (1,) => size(Ji) == (1,) while size(J) == (1,1)
            end
        end
    end
    return J
end

function forwarddiff_color_jacobian!(J::AbstractMatrix{<:Number},
                f,
                x::AbstractArray{<:Number};
                dx = similar(x,size(J,1)),
                colorvec = 1:length(x),
                sparsity = ArrayInterface.has_sparsestruct(J) ? J : nothing)
    forwarddiff_color_jacobian!(J,f,x,ForwardColorJacCache(f,x,dx=dx,colorvec=colorvec,sparsity=sparsity))
end

function forwarddiff_color_jacobian!(J::AbstractMatrix{<:Number},
                f,
                x::AbstractArray{<:Number},
                jac_cache::ForwardColorJacCache)

    t = jac_cache.t
    fx = jac_cache.fx
    dx = jac_cache.dx
    p = jac_cache.p
    colorvec = jac_cache.colorvec
    sparsity = jac_cache.sparsity
    chunksize = jac_cache.chunksize
    color_i = 1
    maxcolor = maximum(colorvec)

    fill!(J, zero(eltype(J)))

    if FiniteDiff._use_findstructralnz(sparsity)
        rows_index, cols_index = ArrayInterface.findstructralnz(sparsity)
    else
        rows_index = 1:size(J,1)
        cols_index = 1:size(J,2)
    end

    # fast path if J and sparsity are both SparseMatrixCSC and have the same sparsity pattern
    sparseCSC_common_sparsity = FiniteDiff._use_sparseCSC_common_sparsity(J, sparsity)

    vecx = vec(x)
    vect = vec(t)
    vecfx= vec(fx)
    vecdx= vec(dx)

    ncols=size(J,2)

    for i in eachindex(p)
        partial_i = p[i]

        if vect isa Array
            @inbounds @simd ivdep for j in eachindex(vect)
                vect[j] = Dual{typeof(ForwardDiff.Tag(f,eltype(vecx)))}(vecx[j], partial_i[j])
            end
        else
            vect .= Dual{typeof(ForwardDiff.Tag(f,eltype(vecx)))}.(vecx, partial_i)
        end

        f(fx,t)
        if !(sparsity isa Nothing)
            for j in 1:chunksize

                if dx isa Array
                    @inbounds @simd for k in eachindex(dx)
                        dx[k] = partials(fx[k], j)
                    end
                else
                    dx .= partials.(fx, j)
                end

                if ArrayInterface.fast_scalar_indexing(dx)
                    #dx is implicitly used in vecdx
                    if sparseCSC_common_sparsity
                        FiniteDiff._colorediteration!(J,vecdx,colorvec,color_i,ncols)
                    else
                        FiniteDiff._colorediteration!(J,sparsity,rows_index,cols_index,vecdx,colorvec,color_i,ncols)
                    end
                else
                    #=
                    J.nzval[rows_index] .+= (colorvec[cols_index] .== color_i) .* dx[rows_index]
                    or
                    J[rows_index, cols_index] .+= (colorvec[cols_index] .== color_i) .* dx[rows_index]
                    += means requires a zero'd out start
                    =#
                    if J isa SparseMatrixCSC
                        @. setindex!((J.nzval,),getindex((J.nzval,),rows_index) + (getindex((colorvec,),cols_index) == color_i) * getindex((vecdx,),rows_index),rows_index)
                    else
                        @. setindex!((J,),getindex((J,),rows_index, cols_index) + (getindex((colorvec,),cols_index) == color_i) * getindex((vecdx,),rows_index),rows_index, cols_index)
                    end
                end
                color_i += 1
                (color_i > maxcolor) && return J
            end
        else
            for j in 1:chunksize
                col_index = (i-1)*chunksize + j
                (col_index > ncols) && return J
                if J isa Array
                    @inbounds @simd for k in 1:size(J,1)
                        J[k, col_index] = partials(vecfx[k], j)
                    end
                else
                    J[:, col_index] .= partials.(vecfx, j)
                end
            end
        end
    end
    return J
end
