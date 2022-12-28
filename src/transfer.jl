abstract type TRANSFER <: Any end

"""
    Independt data transfer for MPIArray.
    parent::MPIArray the parent array to transfer
    send_rk2idcs::Dict{Int, I} a Dict that restore the rank and data indices to transfer.
    recv_rk2ghidcs::Dict{Int, I}
    ghsize::NTuple{N, Int}

"""
struct ArrayTransfer{T, N, I} <: TRANSFER
    parent::MPIArray{T, IA, N} where {IA}
    reqsDatas::Dict{Int, ArrayChunk{T, N}}
    recv_rk2idcs::Dict{Int, I}
    send_rk2idcs::Dict{Int, I}
end


function allgather_VecOrUnitRange(y::UnitRange; comm = MPI.COMM_WORLD)
    data = MPI.Allgather((y, ), comm)
    map(first, data)
end

function allgather_VecOrUnitRange(y::Vector{T}; comm = MPI.COMM_WORLD) where {T<:Integer}
    ls = MPI.Allgather(length(y), comm)
    intervals = [0, cumsum(ls)...]

    datas = zeros(T, sum(ls))
    MPI.Allgatherv!(y, VBuffer(datas, ls), comm)

    return map(i -> datas[(intervals[i]+1):(intervals[i+1])], eachindex(ls))

end

"""
    ArrayTransfer(reqsIndices::NTuple{N, I}, a::MPIArray{T, IA, N}; comm = a.comm, rank = a.myrank, np = MPI.Comm_size(comm)) where {N, I, T, IA}

    create buffer to sync the data in a with reqsIndices.
TBW
"""
function ArrayTransfer(reqsIndices::NTuple{N, Union{UnitRange{Int}, Vector{Int}}}, a::MPIArray{T, IA, N}; comm = a.comm, rank = a.myrank, np = MPI.Comm_size(comm)) where {N, T, IA}
    
    # 收集所有进程需求的 indices
    all_reqIndices      =   map(idc -> allgather_VecOrUnitRange(idc; comm = comm), reqsIndices)
    rank2reqIndices     =   Dict(zip(0:(np-1), zip(all_reqIndices...)))
    rank2indices        =   a.rank2indices

    # 需要接收的 rank 和数据的 indices.
    recv_ranks  =   indice2ranks(reqsIndices, rank2indices)
    recv_rank2indices   =   grank2indices(recv_ranks, reqsIndices, rank2indices)
    # 从每个 rank 接收的数据在临时存储区的位置
    reqsDatas = Dict{Int, ArrayChunk{T, N}}()
    for (rk, idcs) in recv_rank2indices
        reqsDatas[rk] = ArrayChunk(T, idcs...)
    end

    # 需要发送的 rank 和数据在 a.data 内的 indice
    send_ranks = indice2ranks(a.indices, rank2reqIndices)
    send_rank2indices = remoterank2indices(send_ranks, a.indices, rank2reqIndices)

    ArrayTransfer{T, N, eltype(values(recv_rank2indices))}(a, reqsDatas, recv_rank2indices, send_rank2indices)

end

"""
    sync!(t::ArrayTransfer; comm = t.parent.comm, rank = t.parent.myrank, np = MPI.Comm_size(comm))

    sync data in t.
TBW
"""
function sync!(t::ArrayTransfer; comm = t.parent.comm, rank = t.parent.myrank, np = MPI.Comm_size(comm))

    # parent mpi array
    A = t.parent
    # restoring region
    reqsDatas = t.reqsDatas
    # begin sync
    req_all = MPI.Request[]
    begin
        for (ghostrank, indices) in t.recv_rk2idcs
            req = MPI.Irecv!(reqsDatas[ghostrank].data, ghostrank, ghostrank*np + rank, A.comm)
            push!(req_all, req)
        end
        for (remoterank, indices) in t.send_rk2idcs
            req = MPI.Isend(A.data[indices...], remoterank, rank*np + remoterank, A.comm)
            push!(req_all, req)
        end
    end
    MPI.Waitall(MPI.RequestSet(req_all), MPI.Status)

    MPI.Barrier(A.comm)

    return nothing

end